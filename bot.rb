require 'httparty'
require 'airrecord'
require 'telegram/bot'
require 'dotenv/load'

class GeevApi
  SEARCH_URL = 'https://prod.geev.fr/api/v0.19/olditems'.freeze
  DEFAULT_SEARCH_PARAMS = {
    page: 1, page_length: 40, distance: 10_000, type: 'donation',
    closed: false, presentation: 'summary', sort: 'creation'
  }.freeze

  def self.search(search_params)
    return if !search_params[:keywords] || !search_params[:location]

    query = DEFAULT_SEARCH_PARAMS.merge(search_params)
    begin
      HTTParty.get(SEARCH_URL, query: query)
    rescue
      {'ads' => []}
    end
  end
end

class SearchRequests < Airrecord::Table
  Airrecord.api_key = ENV['AIRTABLE_API_KEY']
  self.base_key = ENV['AIRTABLE_BASE_KEY']
  self.table_name = ENV['AIRTABLE_TABLE_NAME']

  def self.all_requests
    begin
      self.all.map{ |line| {keywords: line['keywords'], location: line['location']}}
    rescue
      []
    end
  end
end

class NotifyUser
  def initialize
    @client = Telegram
    @client.bots_config = { default: ENV['TELEGRAM_API_KEY'] }

    @client.bot.get_updates
    @client.bot == Telegram.bots[:default] # true
  end
  def send_notification(title)
    begin
      @client.bot.send_message(chat_id: ENV['TELEGRAM_USER_ID'], text: title, parse_mode: :HTML)
    end
  end
end

class GeevBot
  def initialize
    refresh
    @results = {}
    @already_notified = []
    @notif = NotifyUser.new
  end

  def run
    while @requests.any?
      @requests.each do |request|
        search_results = GeevApi.search(request)
        if @results[request[:keywords]]
          fresh_new_results = search_results['ads']&.reject do |result| 
            @results[request[:keywords]].include?(result['_id']) || 
            @already_notified.include?(result['_id']) ||
            result['last_update_timestamp'] < Time.now.to_i  - 86400
          end
          if fresh_new_results.any?
            fresh_new_results.each do |new_result|
              picture = "https://images.geev.fr/#{new_result['pictures'].first}/squares/300"
              url = "https://www.geev.com/fr/annonce/s/s/#{new_result['_id']}"
              @notif.send_notification("#{new_result['title']}\n#{picture}\n#{url}")
              @already_notified << new_result['_id']
            end
          end
        end
        @results[request[:keywords]] = search_results['ads'].map { |result| result['_id']}
        sleep(60)
      end
      refresh if @next_refresh < Time.now
    end
  end

  private

  def refresh
    @requests = SearchRequests.all_requests
    @next_refresh = Time.now + 1800
  end
end

GeevBot.new.run
