require "openid/message"
require "openid/protocolerror"
require "openid/kvpost"

module OpenID
  class Consumer
    class IdResHandler
      attr_accessor(:openid1_nonce_query_arg_name,
                    :openid1_return_to_identifier_name)

      def initialize(message, return_to, store=nil, endpoint=nil)
        @store = store # Fer the nonce and invalidate_handle
        @message = message
        @endpoint = endpoint
        @return_to = return_to
        @signed_list = nil
        @openid1_nonce_query_arg_name = 'rp_nonce'
        @openid1_return_to_identifier_name = 'openid1_claimed_id'
      end

      def id_res
        check_for_fields
        verify_return_to
        verify_discovery_results
        check_signature
        check_nonce

        signed_fields = signed_list.map {|x| 'openid.' + x}
        SuccessResponse(@endpoint, @message, signed_fields)
      end

      protected

      def server_url
        @endpoint.nil? ? nil : @endpoint.server_url
      end

      def openid_namespace
        @message.get_openid_namespace
      end

      def fetch(field, default=NO_DEFAULT)
        @message.get_arg(OPENID_NS, field, default)
      end

      def signed_list
        if @signed_list.nil?
          signed_list_str = fetch('signed', nil)
          if signed_list_str.nil?
            raise ProtocolError, 'Response missing signed list'
          end

          @signed_list = signed_list_str.split(',', -1)
        end
        @signed_list
      end

      def check_for_fields
        # XXX: if a field is missing, we should not have to explicitly
        # check that it's present, just make sure that the fields are
        # actually being used by the rest of the code in
        # tests. Although, which fields are signed does need to be
        # checked somewhere.
        basic_fields = ['return_to', 'assoc_handle', 'sig', 'signed']
        basic_sig_fields = ['return_to', 'identity']

        case openid_namespace
        when OPENID2_NS
          require_fields = basic_fields + ['op_endpoint']
          require_sigs = basic_sig_fields +
            ['response_nonce', 'claimed_id', 'assoc_handle',]
        when OPENID1_NS
          require_fields = basic_fields + ['identity']
          require_sigs = basic_sig_fields
        else
          raise RuntimeError, "check_for_fields doesn't know about "\
                              "namespace #{openid_namespace.inspect}"
        end

        require_fields.each do |field|
          if !@message.has_key?(OPENID_NS, field)
            raise ProtocolError, "Missing required field #{field}"
          end
        end

        require_sigs.each do |field|
          # Field is present and not in signed list
          if @message.has_key?(OPENID_NS, field) && !signed_list.member?(field)
            raise ProtocolError, "#{field.inspect} not signed"
          end
        end
      end

      def verify_return_to
        msg_return_to = URI.parse(fetch('return_to'))
        verify_return_to_args(msg_return_to)
        if !@return_to.nil?
          verify_return_to_base(msg_return_to)
        end
      end

      def verify_return_to_args(msg_return_to)
        return_to_parsed_query = {}
        if !msg_return_to.query.nil?
          CGI.parse(msg_return_to.query).each_pair do |k, vs|
            return_to_parsed_query[k] = vs[0]
          end
        end
        query = @message.to_post_args
        return_to_parsed_query.each_pair do |rt_key, rt_val|
          msg_val = query[rt_key]
          if msg_val.nil?
            raise ProtocolError, "Message missing return_to argument #{rt_key}"
          elsif msg_val != rt_val
            raise ProtocolError, ("Parameter #{rt_key} value "\
                                  "#{msg_val.inspect} does not match "\
                                  "return_to's value #{rt_val.inspect}")
          end
        end
        @message.get_args(BARE_NS).each_pair do |bare_key, bare_val|
          if return_to_parsed_query[bare_key] != bare_val
            raise ProtocolError, ("Parameter #{bare_key} does not match "\
                                  "return_to URL")
          end
        end
      end

      def verify_return_to_base(msg_return_to)
        app_parsed = URI.parse(@return_to)
        [:scheme, :host, :port, :path].each do |meth|
          if msg_return_to.send(meth) != app_parsed.send(meth)
            raise ProtocolError, "return_to #{meth.to_s} does not match"
          end
        end
      end

      # Raises ProtocolError if the signature is bad
      def check_signature
        if @store.nil?
          assoc = nil
        else
          assoc = @store.get_association(server_url, fetch('assoc_handle'))
        end

        if assoc.nil?
          check_auth
        else
          if assoc.expires_in <= 0
            # XXX: It might be a good idea sometimes to re-start the
            # authentication with a new association. Doing it
            # automatically opens the possibility for
            # denial-of-service by a server that just returns expired
            # associations (or really short-lived associations)
            raise ProtocolError, "Association with #{server_url} expired"
          elsif !assoc.check_message_signature(@message)
            raise ProtocolError, "Bad signature in response from #{server_url}"
          end
        end
      end

      def check_auth
        Util.log("Using 'check_authentication' with #{server_url}")
        begin
          request = create_check_auth_request
        rescue Message::KeyNotFound => why
          raise ProtocolError, "Could not generate 'check_authentication' "\
                               "request: #{why.message}"
        end

        begin
          response = OpenID.make_kv_post(request, server_url)
        rescue ServerError => why
          raise ProtocolError, "Error from #{server_url} during "\
                               "check_authentication: #{why.message}"
        end

        process_check_auth_response(response)
      end

      def create_check_auth_request
        check_args = {}

        # Arguments that are always passed to the server and not
        # included in the signature.
        for k in ['assoc_handle', 'sig', 'signed', 'invalidate_handle']
          val = fetch(k, nil)
          if !val.nil?
            check_args[k] = val
          end
        end

        for k in signed_list
          val = @message.get_aliased_arg(k, NO_DEFAULT)
          check_args[k] = val
        end

        check_args['mode'] = 'check_authentication'
        return Message.from_openid_args(check_args)
      end

      # Process the response message from a check_authentication
      # request, invalidating associations if requested.
      def process_check_auth_response(response)
        is_valid = response.get_arg(OPENID_NS, 'is_valid', 'false')

        invalidate_handle = response.get_arg(OPENID_NS, 'invalidate_handle')
        if !invalidate_handle.nil?
          Util.log("Received 'invalidate_handle' from server #{server_url}")
          if @store.nil?
            Util.log('Unexpectedly got "invalidate_handle" without a store!')
          else
            @store.remove_association(server_url, invalidate_handle)
          end
        end

        if is_valid != 'true'
          raise ProtocolError, ("Server #{server_url} responds that the "\
                                "'check_authentication' call is not valid")
        end
      end

      def check_nonce
        case openid_namespace
        when OPENID1_NS
          nonce = @message.get_arg(BARE_NS, openid1_nonce_query_arg_name)

          # We generated the nonce, so it uses the empty string as the
          # server URL
          server_url = ''
        when OPENID2_NS
          nonce = @message.get_arg(OPENID2_NS, 'response_nonce')
          server_url = self.server_url
        else
          raise StandardError, 'Not reached'
        end

        if nonce.nil?
          raise ProtocolError, 'Nonce missing from response'
        end

        begin
          time, extra = Nonce.split_nonce(nonce)
        rescue ArgumentError => why
          raise ProtocolError, "Malformed nonce: #{nonce.inspect}"
        end

        if !@store.nil? && !@store.use_nonce(server_url, time, extra)
          raise ProtocolError, ("Nonce already used or out of range: "\
                               "#{nonce.inspect}")
        end
      end

      def verify_discovery_results
        case openid_namespace
        when OPENID1_NS
          verify_discovery_results_openid1
        when OPENID2_NS
          verify_discovery_results_openid2
        else
          raise StandardError, "Not reached: #{openid_namespace}"
        end
      end

      def verify_discovery_results_openid2
        to_match = XXXOpenIDServiceEndpoint.new
        to_match.type_uris = [OPENID_2_0_TYPE]
        to_match.claimed_id = fetch('claimed_id', nil)
        to_match.local_id = fetch('identity', nil)
        to_match.server_url = fetch('op_endpoint')

        if to_match.claimed_id.nil? && !to_match.local_id.nil?
          raise ProtocoError, ('openid.identity is present without '\
                               'openid.claimed_id')
        elsif !to_match.claimed_id.nil? && to_match.local_id.nil?
          raise ProtocoError, ('openid.claimed_id is present without '\
                               'openid.identity')

        # This is a response without identifiers, so there's really no
        # checking that we can do, so return an endpoint that's for
        # the specified `openid.op_endpoint'
        elsif to_match.claimed_id.nil?
          @endpoint =
            OpenIDServiceEndpoint.from_op_endpoint_url(to_match.server_url)
        end

        if @endpoint.nil?
          Util.log('No pre-discovered information supplied')
          discover_and_verify(to_match)
        else
          begin
            verify_discovery_single(@endpoint)
          rescue ProtocolError => why
            Util.log("Error attempting to use stored discovery "\
                     "information: #{why.message}")
            Util.log("Attempting discovery to verify endpoint")
            discover_and_verify(to_match)
          end
        end

        if @endpoint.claimed_id != to_match.claimed_id
          @endpoint = @endpoint.dup
          @endpoint.claimed_id = to_match.claimed_id
        end
      end

      def verify_discovery_results_openid1
        claimed_id = @message.get_arg(BARE_NS,
                                      openid1_return_to_identifier_name)

        if claimed_id.nil?
          if @endpoint.nil?
            raise StandardError, ("When using OpenID 1, the claimed ID must "\
                                  "be supplied, either by passing it through "\
                                  "as a return_to parameter or by using a "\
                                  "session, and supplied to the IdResHandler "\
                                  "when it is constructed.")
          else
            claimed_id = @endpoint.claimed_id
          end
        end

        to_match = OpenIDServiceEndpoint.new
        to_match.type_uris = [OPENID_1_1_TYPE]
        to_match.local_id = fetch('identity')
        # Restore delegate information from the initiation phase
        to_match.claimed_id = claimed_id

        if to_match.local_id.nil?
            raise ProtocolError, 'Missing required field "openid.identity"'
        end

        to_match_1_0 = to_match.dup
        to_match_1_0.type_uris = [OPENID_1_0_TYPE]

        if !@endpoint.nil?
          begin
            begin
              verify_discovery_single(to_match)
            rescue TypeURIMismatch
              verify_discovery_single(to_match_1_0)
            end
          rescue ProtocolError => why
            Util.log('Error attempting to use stored discovery information: ' +
                     why.message)
            Util.log('Attempting discovery to verify endpoint')
          else
            return @endpoint
          end
        end

        # Either no endpoint was supplied or OpenID 1.x verification
        # of the information that's in the message failed on that
        # endpoint.
        begin
          discover_and_verify(to_match)
        rescue TypeURIMismatch
          discover_and_verify(to_match_1_0)
        end
      end

      def verify_discovery_single(to_match)
        # Every type URI that's in the to_match endpoint has to be
        # present in the discovered endpoint.
        for type_uri in to_match.type_uris
          if !@endpoint.uses_extension(type_uri)
            raise TypeURIMismatch(type_uri, @endpoint)
          end
        end

        # Fragments do not influence discovery, so we can't compare a
        # claimed identifier with a fragment to discovered information.
        defragged_claimed_id = claimed_id.dup
        defragged_claimed_id.fragment = nil

        if defragged_claimed_id != endpoint.claimed_id
          raise ProtocolError, ("Claimed ID does not match (different "\
                                "subjects!), Expected "\
                                "#{defragged_claimed_id}, got "\
                                "#{@endpoint.claimed_id}")
        end

        if to_match.get_local_id != endpoint.get_local_id
          raise ProtocolError, ("local_id mismatch. Expected "\
                                "#{to_match.get_local_id}, got "\
                                "#{@endpoint.get_local_id}")
        end

        # If the server URL is nil, this must be an OpenID 1
        # response, because op_endpoint is a required parameter in
        # OpenID 2. In that case, we don't actually care what the
        # discovered server_url is, because signature checking or
        # check_auth should take care of that check for us.
        if to_match.server_url.nil?
          if to_match.preferred_namespace == OPENID1_NS
            raise StandardError,
            "The code calling this must ensure that OpenID 2"\
            "responses have a non-none `openid.op_endpoint' and"\
            "that it is set as the `server_url' attribute of the"\
            "`to_match' endpoint."
          end
        elsif to_match.server_url != @endpoint.server_url
          raise ProtocolError, ("OP Endpoint mismatch. Expected"\
                                "#{to_match.server_url}, got "\
                                "#{@endpoint.server_url}")
        end
      end

      # Given an endpoint object created from the information in an
      # OpenID response, perform discovery and verify the discovery
      # results, returning the matching endpoint that is the result of
      # doing that discovery.
      def discover_and_verify(to_match)
        Util.log("Performing discovery on #{to_match.claimed_id}")
        _, services = discover(to_match.claimed_id)
        if services.length == 0
          # XXX: this might want to be something other than
          # ProtcolError. In Python, it's DiscoveryFailure
          raise ProtcolError("No OpenID information found at "\
                             "#{to_match.claimed_id}")
        end
        verify_discovered_services(services, to_match)
      end


      def verify_discovered_services(services, to_match)
        # Search the services resulting from discovery to find one
        # that matches the information from the assertion
        failure_messages = []
        for endpoint in services
          begin
            verify_discovery_single(endpoint, to_match)
          rescue ProtocolError => why
            failure_messages << why.message
          else
            # It matches, so discover verification has
            # succeeded. Return this endpoint.
            @endpoint = endpoint
            return
          end
        end

        Util.log("Discovery verification failure for #{to_match.claimed_id}")
        failure_messages.each do |failure_message|
          Util.log(" * Endpoint mismatch: " + failure_message)
        end

        # XXX: is DiscoveryFailure in Python OpenID
        raise ProtocolError("No matching endpoint found after "\
                            "discovering #{to_match.claimed_id}")
      end
    end
  end
end