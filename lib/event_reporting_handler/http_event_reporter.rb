# License: Apache 2.0
#
# Copyright 2015, Bloomberg Finance L.P.
#
require 'chef/event_dispatch/base'
require 'chef/whitelist'
require 'raven'


module BloombergLP
  module EventReportingHandler
    class HttpEventReporter < Chef::EventDispatch::Base
      def initialize(http_config, sentry_config, run_status)
        @http_url = http_config['url']
        @whitelist_attributes = Chef::Whitelist.filter(run_status.node, http_config['whitelist_attributes'])
        @node = run_status.node
        Raven.configure(true) do |config|
          config.ssl_verification = sentry_config['verify_ssl'] || true
          config.dsn = sentry_config['dsn']
          config.logger = ::Chef::Log
          config.current_environment = @node.chef_environment
          config.environments = [@node.chef_environment]
          config.send_modules = Gem::Specification.respond_to?(:map)
        end
        Raven.logger.debug 'Raven ready to report errors'
      end

      def run_started(run_status)
        @chef_run_id = run_status.run_id
        @node_fqdn = @node.name
        publish_event(:run_started)
      end

      # Called at the end a successful Chef run.
      def run_completed(_node)
        publish_event(:run_completed)
      end

      # Called at the end of a failed Chef run.
      def run_failed(exception)
        sentry_event_id = report_to_sentry(exception)
        publish_event(:run_failed, sentry_event_id: sentry_event_id)
      end

      private

      def report_to_sentry(exception)
        Raven.logger.info 'Logging run failure to Sentry server'
        if exception
          evt = Raven::Event.capture_exception(exception)
        else
          evt = Raven::Event.new do |event|
            event.message = 'Unknown error during Chef run'
            event.level = :error
          end
        end
        # Use the node name, not the FQDN
        evt.server_name = @node.name
        Raven.send(evt)
        evt.id
      end

      def publish_event(event, custom_attributes = {})
        json_to_publish = get_json_from_event(event, custom_attributes.merge(@whitelist_attributes))
        begin
          uri = URI(@http_url)
          res = Net::HTTP.start(uri.host, uri.port) do |http|
            http.post(uri.path, json_to_publish, 'Content-Type' => 'application/json')
          end
          case res
          when Net::HTTPSuccess, Net::HTTPRedirection
            Chef::Log.debug("Successfully sent http request with #{json_to_publish} to #{@http_url}")
          else
            Chef::Log.warn("Error in sending http request to #{@http_url} Code is #{res.code} Msg is #{res.message}")
          end
        rescue StandardError => e # catch all exceptions so that chef run does not fail
          Chef::Log.warn("Exception raised when sending http request to #{@http_url} : #{e}")
        end
      end

      def get_json_from_event(event, custom_attributes)
        deploy_event = { node_fqdn: @node_fqdn, sub_type: event, occurred_at: Time.now.to_s }.merge(custom_attributes)
        { deploy_event: deploy_event }.to_json
      end
    end
  end
end
