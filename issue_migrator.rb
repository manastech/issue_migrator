require "httpclient"
require "json"
require "base64"
require "optparse"
require "yaml"

options = {}

OptionParser.new do |opts|
  opts.on("-b", "--bitbucket REPOSITORY", "BitBucket repository") do |repo|
    options[:bitbucket_repo] = repo
  end
  opts.on("-g", "--github REPOSITORY", "GitHub repository") do |repo|
    options[:github_repo] = repo
  end
  opts.on("-u", "--github-user USER", "GitHub user") do |user|
    options[:github_user] = user
  end
  opts.on("-m", "--map-file FILE", "User mapping file (used to assign issue responsibles)") do |map_file|
    options[:map] = YAML.load_file(map_file)
  end
  opts.on("--responsibles", "List responsible users and exit") do
    options[:action] = :list_responsibles
  end
end.parse!

unless options[:action] == :list_responsibles
  unless options[:github_repo] && options[:github_user]
    puts "GitHub repository and user must be specified"
    exit 1
  end

  print "GitHub password for user #{options[:github_user]}: "
  system "stty -echo"
  password = STDIN.gets.chomp
  system "stty echo"
  puts

  AUTHORIZATION_HEADER = {"Authorization" => "Basic #{Base64.strict_encode64("#{options[:github_user]}:#{password}")}"}
end

def parse_response(response, expected_status = 200)
  if response.status != expected_status
    p response
    exit(1)
  end
  JSON.load response.body
end

issues = {}
issue_ids = []
client = HTTPClient.new

print "Loading issues..."
start = 0
loop do
  json = parse_response(client.get("https://bitbucket.org/api/1.0/repositories/#{options[:bitbucket_repo]}/issues?start=#{start}&limit=50&sort=local_id"))
  response_issues = json["issues"]
  break if response_issues.length == 0

  response_issues.each do |issue|
    id = issue["local_id"]
    issues[id] = issue
    issue_ids << id
  end
  start += response_issues.length
  print "."
end

puts

if options[:action] == :list_responsibles
  responsibles = []
  issues.each do |id, issue|
    if issue["responsible"]
      responsibles << issue["responsible"]["username"]
    end
  end
  p responsibles.uniq!

  if options[:map]
    responsibles.each do |resp|
      puts "User #{resp} is not in the mapping file" unless options[:map][resp]
    end
  end

  exit 0
end

print "Loading milestones..."
bitbucket_milestones = parse_response(client.get("https://bitbucket.org/api/1.0/repositories/#{options[:bitbucket_repo]}/issues/milestones"))
github_milestones = []
page = 1
loop do
  print "."
  milestones_page = parse_response(client.get("https://api.github.com/repos/#{options[:github_repo]}/milestones?page=#{page}"))
  break if milestones_page.length == 0
  github_milestones.concat milestones_page
  page += 1
end
puts

github_milestones = Hash[github_milestones.map { |m| [m["title"], m["number"]] }]
milestones = {}

bitbucket_milestones.each do |m|
  milestones[m["name"]] = github_milestones[m["name"]] || begin
    puts "Creating milestone #{m["name"]}"
    new_milestone = parse_response(client.post("https://api.github.com/repos/#{options[:github_repo]}/milestones", body: {title: m["name"]}.to_json, header: AUTHORIZATION_HEADER), 201)
    new_milestone["number"]
  end
end
puts

print "Loading comments..."

threads = 10.times.map do
  Thread.new do
    while id = issue_ids.shift
      comments = parse_response(client.get("https://bitbucket.org/api/1.0/repositories/#{options[:bitbucket_repo]}/issues/#{id}/comments"))
      comments.sort_by! { |x| x["utc_created_on"] }
      issues[id]["comments"] = comments
      print "."
    end
  end
end

threads.each &:join
puts

issue_labels = {}
last_issue_id = 0

issues.each do |id, issue|
  last_issue_id += 1

  while last_issue_id < id
    puts "Deleted issue \##{last_issue_id}"
    dummy_issue = {title: "Deleted Issue", body: "This issue was deleted"}
    dummy_issue_response = parse_response(client.post("https://api.github.com/repos/#{options[:github_repo]}/issues", body: dummy_issue.to_json, header: AUTHORIZATION_HEADER), 201)
    dummy_id = dummy_issue_response["number"]
    if dummy_id != last_issue_id
      puts "Could not create issue with id #{last_issue_id}. Please delete the repository and create it again."
      exit 1
    end

    parse_response(client.request("PATCH", "https://api.github.com/repos/#{options[:github_repo]}/issues/#{dummy_id}", body: {state: "closed"}.to_json, header: AUTHORIZATION_HEADER))
    last_issue_id += 1
  end

  puts "BitBucket issue \##{id}"

  author = issue["reported_by"]
  author = author ? author["display_name"] : "Anonymous"
  new_issue = {
    title: issue["title"],
    body: issue["content"] +
      "\n\n\n---------------------------------------\n" \
      "- Imported from BitBucket: https://bitbucket.org/#{options[:bitbucket_repo]}/issue/#{id}\n" \
      "- Originally Reported By: #{author}\n" \
      "- Originally Created At: #{issue["utc_created_on"]}",
    labels: [issue["metadata"]["kind"]]
  }

  if milestone_name = issue["metadata"]["milestone"]
    new_issue[:milestone] = milestones[milestone_name]
  end

  if options[:map] && issue["responsible"]
    bitbucket_user = issue["responsible"]["username"]
    if github_user = options[:map][bitbucket_user]
      new_issue[:assignee] = github_user
    end
  end

  if issue["priority"] != "major"
    new_issue[:labels] << issue["priority"]
  end

  if issue["metadata"]["component"]
    new_issue[:labels] << issue["metadata"]["component"]
  end

  new_issue_response = parse_response(client.post("https://api.github.com/repos/#{options[:github_repo]}/issues", body: new_issue.to_json, header: AUTHORIZATION_HEADER), 201)
  new_id = new_issue_response["number"]

  if new_id != id
    puts "FATAL: Could not create issue with same id. BitBucket (#{id}) != GitHub (#{new_id})"
    exit 1
  end

  issue_labels[id] = new_issue[:labels]
end

threads = 10.times.map do
  Thread.new do
    while x = issue_labels.shift
      id, labels = x
      issue = issues[id]

      issue["comments"].each do |comment|
        puts "Comment by #{comment["author_info"]["display_name"]} on issue #{id}"
        body = comment["content"] +
          "\n\n\n---------------------------------------\n" \
          "- Original comment by *#{comment["author_info"]["display_name"]}* on #{issue["utc_created_on"]}\n"
        parse_response(client.post("https://api.github.com/repos/#{options[:github_repo]}/issues/#{id}/comments", body: {body: body}.to_json, header: AUTHORIZATION_HEADER), 201)
      end

      issue_update = case issue["status"]
      when "new", "open"
        next
      when "resolved", "closed"
        {state: "closed"}
      when "on hold"
        {labels: labels + ["on hold"]}
      when "invalid", "duplicate", "wontfix"
        {state: "closed", labels: labels + [issue["status"]]}
      end

      puts "Setting status for '#{issue["status"]}' on issue #{id}"
      parse_response(client.request("PATCH", "https://api.github.com/repos/#{options[:github_repo]}/issues/#{id}", body: issue_update.to_json, header: AUTHORIZATION_HEADER))
    end
  end
end

threads.each &:join
