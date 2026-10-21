import CmuxNextSettings
import Foundation

/// The two outside reads of the Chief view gallery, as pure functions over the bytes, so the tests
/// need no network:
/// - Fleet: the CI fleet dashboard's `data.json`, trimmed to what the Fleet view shows
///   (types.ts `FleetReply`). The dashboard's address is the person's to set (the view's field, or
///   `CMUX_CHIEF_VIEWS_FLEET_URL`); none is built in.
/// - Landing: GitHub's issue search for the repository's open pull requests into the base branch
///   and those merged since the start of today (types.ts `LandingReply`).
struct ChiefViewsFeeds {
    /// The repository and base branch the Landing view reads.
    static let repo = "manaflow-ai/cmux"
    static let base = "feat-cmux-next"
    /// The most pull requests one search returns (GitHub's page size cap is 100).
    static let pageSize = 60

    // MARK: Fleet

    /// The dashboard's `data.json` under `base` (the page the person named).
    static func fleetDataURL(_ base: URL) -> URL {
        base.lastPathComponent == "data.json" ? base : base.appendingPathComponent("data.json")
    }

    /// A dashboard address the person may set: http or https with a host, nothing else.
    static func validFleetURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        // Plain http only where the network already encrypts or never leaves the machine.
        let privateHost = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".ts.net")
        return scheme == "https" || (scheme == "http" && privateHost) ? url : nil
    }

    /// The Fleet view's reply from the dashboard's `data.json`: each mini's load, cores, CPU and
    /// free memory, its busy and online runners, the queue's length and each PR's last run.
    /// Nil when the bytes are not the dashboard's (no `minis` list).
    static func fleetReply(_ data: Data) -> JSONValue? {
        guard let root = try? JSONValue.parse(data), let minis = root["minis"]?.arrayValue else { return nil }
        var runners: [String: (busy: Int, online: Int)] = [:]
        for runner in root["runners"]?.arrayValue ?? [] {
            guard let host = runner["host"]?.stringValue else { continue }
            var count = runners[host] ?? (0, 0)
            if runner["status"]?.stringValue == "online" {
                count.online += 1
                if runner["busy"]?.boolValue == true { count.busy += 1 }
            }
            runners[host] = count
        }
        let machines: [JSONValue] = minis.compactMap { mini in
            guard let host = mini["host"]?.stringValue else { return nil }
            let count = runners[host] ?? (0, 0)
            return .object([
                "host": .string(host),
                "load": number(mini["load"]?.arrayValue?.first ?? mini["load"]),
                "ncpu": number(mini["ncpu"]),
                "cpuPct": number(mini["cpu_pct"]),
                "memFreePct": number(mini["mem_free_pct"]),
                "runnersBusy": JSONValue(count.busy),
                "runnersOnline": JSONValue(count.online),
                "error": mini["error"]?.stringValue.map(JSONValue.string) ?? .null,
            ])
        }
        let prs: [JSONValue] = (root["recent_prs"]?.arrayValue ?? []).compactMap { run in
            guard let number = run["pr"]?.intValue else { return nil }
            return .object([
                "number": JSONValue(number),
                "title": .string(run["title"]?.stringValue ?? ""),
                "branch": run["branch"]?.stringValue.map(JSONValue.string) ?? .null,
                "status": .string(run["status"]?.stringValue ?? ""),
            ])
        }
        let queued = root["queued"]?.arrayValue?.count ?? root["queued"]?.intValue ?? 0
        return .object([
            "updated": root["updated"]?.stringValue.map(JSONValue.string) ?? .null,
            "machines": .array(machines),
            "queued": JSONValue(queued),
            "prs": .array(prs),
        ])
    }

    private static func number(_ value: JSONValue?) -> JSONValue {
        value?.doubleValue.map(JSONValue.number) ?? .null
    }

    // MARK: Landing

    /// The two searches: open PRs into the base, and PRs into it merged on or after `day`
    /// (`yyyy-MM-dd`, UTC; the page keeps only the person's local today).
    static func landingSearchURLs(mergedSince day: String) -> (open: URL, merged: URL)? {
        let scope = "repo:\(repo) is:pr base:\(base)"
        func search(_ query: String) -> URL? {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "api.github.com"
            components.path = "/search/issues"
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "per_page", value: String(pageSize)),
            ]
            return components.url
        }
        guard let open = search("\(scope) is:open"), let merged = search("\(scope) is:merged merged:>=\(day)") else { return nil }
        return (open, merged)
    }

    /// The UTC day before `now`'s, so a merge after local midnight anywhere is in the search.
    static func searchDay(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now.addingTimeInterval(-86_400))
    }

    /// The pull requests of one search reply (`items`), in types.ts `LandingPR` form; nil when
    /// the bytes are not a search reply.
    static func landingPRs(_ data: Data) -> [JSONValue]? {
        guard let root = try? JSONValue.parse(data), let items = root["items"]?.arrayValue else { return nil }
        return items.compactMap { item in
            guard let number = item["number"]?.intValue, let title = item["title"]?.stringValue,
                  let url = item["html_url"]?.stringValue, url.hasPrefix("https://github.com/") else { return nil }
            let labels = (item["labels"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            return .object([
                "number": JSONValue(number),
                "title": .string(title),
                "url": .string(url),
                "author": item["user"]?["login"]?.stringValue.map(JSONValue.string) ?? .null,
                "labels": .array(labels.map(JSONValue.string)),
                "draft": .bool(item["draft"]?.boolValue ?? false),
                "createdAt": item["created_at"]?.stringValue.map(JSONValue.string) ?? .null,
                "mergedAt": item["pull_request"]?["merged_at"]?.stringValue.map(JSONValue.string) ?? .null,
            ])
        }
    }

    /// The Landing view's reply from the two searches.
    static func landingReply(open: [JSONValue], merged: [JSONValue]) -> JSONValue {
        .object(["repo": .string(repo), "base": .string(base), "open": .array(open), "merged": .array(merged)])
    }

    /// A pull request link the page may open: an https github.com page of the repository.
    static func validPullRequestURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host == "github.com", url.user == nil,
              !url.pathComponents.contains(".."), url.standardized.path.hasPrefix("/\(repo)/") else { return nil }
        return url
    }
}
