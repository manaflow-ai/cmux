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
    /// Nil when the bytes are not the dashboard's (no `minis` list). Shaped by the Rust
    /// `welcome.fleetReply` op.
    static func fleetReply(_ data: Data) -> JSONValue? {
        let reply: Reply = welcomeRule("welcome.fleetReply", Body(data), fallback: Reply(reply: nil))
        return reply.reply
    }

    // MARK: Landing

    /// The two searches: open PRs into the base, and PRs into it merged on or after `day`
    /// (`yyyy-MM-dd`, UTC; the page keeps only the person's local today).
    static func landingSearchURLs(mergedSince day: String) -> (open: URL, merged: URL)? {
        let urls: SearchURLs? = welcomeRule("welcome.landingSearchUrls", ["day": day], fallback: nil)
        guard let urls, let open = URL(string: urls.open), let merged = URL(string: urls.merged) else { return nil }
        return (open, merged)
    }

    /// The UTC day before `now`'s, so a merge after local midnight anywhere is in the search.
    static func searchDay(_ now: Date) -> String {
        let reply: Day = welcomeRule("welcome.searchDay", ["now": now.timeIntervalSince1970], fallback: Day(day: ""))
        return reply.day
    }

    /// The pull requests of one search reply (`items`), in types.ts `LandingPR` form; nil when
    /// the bytes are not a search reply.
    static func landingPRs(_ data: Data) -> [JSONValue]? {
        let reply: PRs = welcomeRule("welcome.landingPrs", Body(data), fallback: PRs(prs: nil))
        return reply.prs
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

    // MARK: Wire

    /// A fetched body, as text for the op to parse.
    private nonisolated struct Body: Encodable {
        let body: String
        init(_ data: Data) { body = String(decoding: data, as: UTF8.self) }
    }

    private nonisolated struct Reply: Decodable { let reply: JSONValue? }
    private nonisolated struct SearchURLs: Decodable { let open: String; let merged: String }
    private nonisolated struct Day: Decodable { let day: String }
    private nonisolated struct PRs: Decodable { let prs: [JSONValue]? }
}
