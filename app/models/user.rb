class User < ActiveRecord::Base
  acts_as_mappable
  belongs_to :startup
  belongs_to :meeting
  has_many :authentications, :dependent => :destroy
  has_many :organized_meetings, :class_name => 'Meeting', :foreign_key => 'organizer_id'
  has_many :sent_messages, :foreign_key => 'sender_id', :class_name => 'Message'
  has_many :received_messages, :foreign_key => 'recipient_id', :class_name => 'Message'
  has_many :comments
  has_many :notifications, :dependent => :destroy
  has_many :meeting_messages
  has_many :invites, :foreign_key => 'to_id'
  has_many :awesomes
  has_many :sent_nudges, :class_name => 'Nudge', :foreign_key => 'from_id'
  has_many :user_actions, :as => :attachable


  # Include default devise modules. Others available are:
  # :token_authenticatable, :confirmable,
  # :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable #, :confirmable #, :omniauthable

  # Setup accessible (or protected) attributes for your model
  attr_accessible :email, :password, :password_confirmation, :remember_me, :name, :skill_list, :startup, :mentor, :investor, :location, :phone, :startup_id, :settings, :meeting_id, :one_liner, :bio, :facebook_url, :linkedin_url, :github_url, :dribbble_url, :blog_url, :pic, :remote_pic_url, :pic_cache, :remove_pic

  serialize :settings, Hash

  validate :email_is_not_nreduce

  before_create :set_default_settings
  before_save :geocode_location

  acts_as_taggable_on :skills

  mount_uploader :pic, PicUploader # carrierwave file uploads

  def self.settings_labels
    {
      'email_on' =>
        {
        'docheckin' => 'Reminder to Check-in',
        'comment' => 'New Comment', 
        'meeting' => 'Meeting Reminder', 
        'checkin' => 'New Checkin', 
        'relationship' => 'Relationships',
        }
    }
  end

  def self.default_settings
    {'email_on' => User.settings_labels['email_on'].keys}
  end

  def self.force_email_on
    ['nudge']
  end

  def received_nudges
    self.startup.nudges
  end

  def settings
    self['settings'].blank? ? [] : self['settings']
  end

  def update_unread_notifications_count
    self.unread_nc = self.notifications.unread.count
    self.save
  end

  def mark_all_notifications_read
    if Notification.mark_all_read_for(self)
      self.unread_nc = 0
      self.save
    else 
      false
    end
  end

    # Returns boolean if user should be emailed for a specific action (action being the object class)
  def email_for?(class_name)
    begin
      return true if User.force_email_on.include?(class_name)
      !self.email.blank? and self.settings['email_on'].include?(class_name)
    rescue # in case array isn't set
      false
    end
  end

  def first_name
    self.name.blank? ? '' : self.name.sub(/\s+.*/, '')
  end

  def awesome_id_for_object(object)
    cached = self.cached_awesome_ids
    # when hash is retrieved from cache, id keys are converted to strings so have to look for string
    return cached[object.class.to_s][object.id.to_s] if cached[object.class.to_s] and cached[object.class.to_s][object.id.to_s]
    return nil
  end

    # returns hash all objects this user has 'awesomed' organized by object class. also includes awesome id
    # eg {:comment => {23 (comment id) => 12 (awesome id), 12 => 52}, :checkin => {56 => 54, 55 => 33}}
  def cached_awesome_ids
    Cache.get(['awesome_ids', self]){
      ids = {}
      self.awesomes.each{|a| ids[a.awsm_type] ||= {}; ids[a.awsm_type][a.awsm_id.to_s] = a.id }
      ids
    }
  end

  def commented_on_checkin_ids
    Cache.get(['cids', self]){
      self.comments.map{|c| c.checkin_id }
    }
  end

  def mailchimp!
    return true if mailchimped?
    return false unless email.present?
    return false unless Settings.apis.mailchimp.enabled

    h = Hominid::API.new(Settings.apis.mailchimp.api_key)

    h.list_subscribe(Settings.apis.mailchimp.startup_list_id, email, {}, "html", false) unless self.startup_id.blank?
    h.list_subscribe(Settings.apis.mailchimp.mentor_list_id, email, {}, "html", false) if self.mentor?
    h.list_subscribe(Settings.apis.mailchimp.everyone_list_id, email, {}, "html", false)

    self.mailchimped = true
    self.save!

  rescue => e
    Rails.logger.error "Unable put #{email} to mailchimp"
    Rails.logger.error e
  end

    # Calculate engagement metrics for all users
    # Simply calculates avg number of comments given per startup per week
    # @from_time (start metrics on this date)
    # @to_time (optional - end metrics on this date, defaults to now)
  def self.calculate_engagement_metrics(from_time, to_time = nil, dont_save = false, max_comments_per_checkin = 2)
    to_time ||= Time.now
    return 'From time is not after to time' if from_time > to_time

    # Grab all comments that everyone created during the time period
    comments_by_user = Hash.by_key(Comment.where(['created_at > ? AND created_at < ?', from_time.to_s(:db), to_time.to_s(:db)]).all, :user_id, nil, true)

    # Grab all completed checkins completed during this time period to see how many you did/ didn't comment on
    checkins_by_startup = Hash.by_key(Checkin.where(['created_at > ? AND created_at < ?', from_time.to_s(:db), to_time.to_s(:db)]).completed.all, :startup_id, nil, true)

    # Looping through all startups
    #
    # Cheating a bit here - really should see who you're connected to each week, as it penalizes you for adding new connections after the commenting window is open
    results = {}
    Startup.includes(:team_members).onboarded.all.each do |startup|
      num_for_startup = num_checkins = 0
      results[startup.id] = {}
      results[startup.id][:total] = nil

      checkins_by_this_startup = Hash.by_key(checkins_by_startup[startup.id], :id)

      # How many checkins did your connected startups make?
      Relationship.all_connection_ids_for(startup).map do |startup_id|
        num_checkins += checkins_by_startup[startup_id].size unless checkins_by_startup[startup_id].blank?
      end

      startup.team_members.each do |user|
        rating = nil

        # Skip if their connections haven't made any checkins
        if num_checkins > 0
          num_comments_by_user = 0
          # What is total number of comments on these checkins?
          # - ignore comments on your own checkins
          # - max 2 comments per checkin are counted
          unless comments_by_user[user.id].blank?
            comments_by_checkin_id = Hash.by_key(comments_by_user[user.id], :checkin_id, nil, true)
            comments_by_checkin_id.each do |checkin_id, comments|
              # skip if this is one of their checkins
              next unless checkins_by_this_startup[checkin_id].blank?

              # limit count to max comments per checkin number
              num_comments_by_user += (comments.size > max_comments_per_checkin ? max_comments_per_checkin : comments.size)
            end
          end
          
          rating = (num_comments_by_user.to_f / num_checkins.to_f).round(3)
          num_for_startup += rating
        end
        user.rating = rating
        user.save(:validate => false) unless dont_save
        results[startup.id][user.id] = rating
      end

      # calculate after for startup
      rating = nil
      rating = (num_for_startup.to_f / startup.team_members.size.to_f).round(3) unless num_checkins == 0
      startup.rating = rating
      startup.save(:validate => false) unless dont_save
      results[startup.id][:total] = rating
    end
    results
  end

  #
  # OMNIAUTH LOGIC
  #
  
  def self.auth_params_from_omniauth(omniauth)
    prms = {:provider => omniauth['provider'], :uid => omniauth['uid']}
    if omniauth['credentials']
      prms[:token] = omniauth['credentials']['token'] if omniauth['credentials']['token']
      prms[:secret] = omniauth['credentials']['secret'] if omniauth['credentials']['secret']
    end
    prms
  end

  def apply_omniauth(omniauth)
    begin
      # TWITTER
      if omniauth['provider'] == 'twitter'
        logger.info omniauth['info'].inspect
        self.name = omniauth['info']['name'] if name.blank? and !omniauth['info']['name'].blank?
        self.external_pic_url = omniauth['info']['image'] unless omniauth['info']['image'].blank?
        self.location = omniauth['info']['location'] if !omniauth['info']['location'].blank?
        self.twitter = omniauth['info']['nickname']
      elsif omniauth['provider'] == 'linkedin'
        self.name = omniauth['info']['name'] if name.blank? and !omniauth['info']['name'].blank?
        self.external_pic_url = omniauth['info']['image'] unless omniauth['info']['image'].blank?
        self.linkedin_url = omniauth['info']['urls']['public_profile'] unless omniauth['info']['urls'].blank? or omniauth['info']['urls']['public_profile'].blank?
      # FACEBOOK
      elsif omniauth['provider'] == 'facebook'
        self.name = omniauth['user_info']['name'] if name.blank? and !omniauth['user_info']['name'].blank?
        if self.email.blank?
          self.email = omniauth['extra']['user_hash']['email'] if omniauth['extra'] && omniauth['extra']['user_hash'] && !omniauth['extra']['user_hash']['email'].blank?
          self.email = omniauth['user_info']['email'] unless omniauth['user_info']['email'].blank?
        end
        self.email = 'null@null.com' if self.email.blank?
        if omniauth['extra']['user_hash']['location'] and !omniauth['extra']['user_hash']['location']['name'].blank?
          self.location = omniauth['extra']['user_hash']['location']['name']
        end
      end
    rescue
      logger.warn "ERROR applying omniauth with data: #{omniauth}"
    end
    authentications.build(User.auth_params_from_omniauth(omniauth))
  end

  def password_required?
    (authentications.empty? || !password.blank?) && super
  end
  
  def uses_password_authentication?
    !self.encrypted_password.blank?
  end
  
   # Returns boolean if user is authenticated with a provider 
   # Parameter: provider_name (string)
  def authenticated_for?(provider_name)
    authentications.where(:provider => provider_name).count > 0
  end

  def internal_email
    "#{twitter || self.id}@users.nreduce.com"
  end

  def hipchat_name
    n = !self.name.blank? ? self.name : self.twitter.sub('@', '')
    s = self.startup
    if !s.blank?
      n += " | #{s.name}"
    else
      # Name needs to have first and last name or else hipchat considers it invalid
      n += ' S12' if(n.split(/\s+/).size < 2)
    end
    n
  end

  def hipchat?
    hipchat_username.present?
  end

  def reset_hipchat_account!
    self.hipchat_username = nil
    self.generate_hipchat!
  end

  def generate_hipchat!
    return if hipchat?
    pass = NreduceUtil.friendly_token.to_s[0..8]
    prms = {:auth_token => Settings.apis.hipchat.token,
            :email => internal_email,
            :name => hipchat_name, 
            :title => 'nReducer', 
            :is_group_admin => 0,
            :password => pass, 
            :timezone => 'UTC'}

    # Have to post manually to API because for some reason gem doesn't pass auth token properly
    uri = URI.parse("https://api.hipchat.com/v1/users/create")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(prms)
    response = http.request(request)
    if response.code == '200'
      self.hipchat_username = internal_email
      self.hipchat_password = pass
      self.save!
    else
      false
    end
    # hipchat = HipChat::API.new(Settings.apis.hipchat.token)
    # pass = NreduceUtil.friendly_token.to_s[0..8]
    # if hipchat.users_create(internal_email, name, 'nReducer', 0, pass)
    #   self.hipchat_username = internal_email
    #   self.hipchat_password = pass
    #   self.save!
    # else
    #   false
    # end
  end

  def geocode_from_ip(ip_address)
    begin
      res = User.geocode(ip_address)
      unless res.blank?
        self.location = [res.city, res.state, res.country_code].delete_if{|i| i.blank? }.join(', ')
        return true
      end
    rescue
      # do nothing
    end
    false
  end

  protected

  def email_is_not_nreduce
    if !self.email.blank? and self.email.match(/\@\w+\.nreduce\.com$/) != nil
      self.errors.add(:email, 'is not valid')
      false
    else
      true
    end
  end

  def set_default_settings
    self.settings = User.default_settings if self.settings.blank?
  end

  def geocode_location
    return true if !Rails.env.production? or self.location.blank? or (!self.location_changed? and !self.lat.blank?)
    begin
      res = User.geocode(self.location)
      self.lat, self.lng = res.lat, res.lng
    rescue
      self.errors.add(:location, "could not be geocoded")
    end
  end
end
