import CmuxNextSettings
public import Foundation

/// The pull request of a chat folder's branch, as the chat header's chip shows it (cx-tcwj, Codex
/// desktop's PR chip): read from `gh pr view --json` ``fields``. The chip's popover (cx-ncc.77.1)
/// shows the title, the review decision and each check.
public nonisolated struct AgentPanePullRequest: Equatable, Sendable {
    /// The `gh pr view --json` fields read.
    public static let fields = "url,number,title,state,isDraft,reviewDecision,mergeable,statusCheckRollup,createdAt,mergedAt"
    /// The most checks the popover lists.
    static let maximumChecks = 50

    /// One check: its name, `passed`, `failed` or `pending`, and its run's page when that is https.
    public struct Check: Equatable, Sendable {
        public var name: String
        public var state: String
        public var url: String?

        public init(name: String, state: String, url: String?) {
            self.name = name
            self.state = state
            self.url = url
        }
    }

    /// Its checks summed: `failing` when any failed, else `pending` when any has not finished, else
    /// `passing`, or `none` without checks. A skipped or neutral check counts as passed.
    public struct Checks: Equatable, Sendable {
        public var state: String
        public var passed: Int
        public var total: Int

        public init(state: String, passed: Int, total: Int) {
            self.state = state
            self.passed = passed
            self.total = total
        }
    }

    /// Always https.
    public var url: String
    public var number: Int
    public var title: String
    /// `open`, `draft`, `merged` or `closed`.
    public var state: String
    /// `approved`, `changes_requested`, `review_required`, or empty without a required review.
    public var review: String
    /// `mergeable`, `conflicting`, or empty while GitHub works it out.
    public var mergeable: String
    public var checks: Checks
    /// Each check, failed first, then running, then passed, at most ``maximumChecks``.
    public var checkList: [Check]
    /// When it was opened and when it merged, as GitHub's ISO 8601 text; empty when unknown or not
    /// merged. Agent PR cycle time runs between the two (hq#1920).
    public var createdAt: String
    public var mergedAt: String

    public init(url: String, number: Int, title: String = "", state: String, review: String = "", mergeable: String = "",
                checks: Checks, checkList: [Check] = [], createdAt: String = "", mergedAt: String = "") {
        self.url = url
        self.number = number
        self.title = title
        self.state = state
        self.review = review
        self.mergeable = mergeable
        self.checks = checks
        self.checkList = checkList
        self.createdAt = createdAt
        self.mergedAt = mergedAt
    }

    /// Nil unless `ghView` is gh's answer with an https url and a number.
    public init?(ghView: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: ghView) as? [String: Any],
              let url = object["url"] as? String, url.hasPrefix("https://"), !url.contains(where: \.isWhitespace),
              let number = object["number"] as? Int else { return nil }
        let state = (object["state"] as? String)?.lowercased() ?? "open"
        let rollup = object["statusCheckRollup"] as? [[String: Any]] ?? []
        let mergeable = (object["mergeable"] as? String)?.lowercased() ?? ""
        self.init(url: url, number: number, title: object["title"] as? String ?? "",
                  state: state == "open" && object["isDraft"] as? Bool == true ? "draft" : state,
                  review: (object["reviewDecision"] as? String)?.lowercased() ?? "",
                  mergeable: mergeable == "unknown" ? "" : mergeable,
                  checks: Self.checks(rollup), checkList: Self.checkList(rollup),
                  createdAt: object["createdAt"] as? String ?? "", mergedAt: object["mergedAt"] as? String ?? "")
    }

    /// Each check run or commit status with its outcome, failed first; links only when https.
    static func checkList(_ rollup: [[String: Any]]) -> [Check] {
        let order = ["failed": 0, "pending": 1, "passed": 2]
        let list = rollup.map { check in
            let link = (check["detailsUrl"] as? String) ?? (check["targetUrl"] as? String)
            return Check(name: (check["name"] as? String) ?? (check["context"] as? String) ?? "check",
                         state: outcome(check),
                         url: link.flatMap { $0.hasPrefix("https://") && !$0.contains(where: \.isWhitespace) ? $0 : nil })
        }
        let sorted = list.enumerated().sorted { (order[$0.element.state] ?? 3, $0.offset) < (order[$1.element.state] ?? 3, $1.offset) }
        return sorted.prefix(maximumChecks).map(\.element)
    }

    /// A check run (`status`, `conclusion`) or a commit status (`state`), each as passed, failed or
    /// still running.
    static func checks(_ rollup: [[String: Any]]) -> Checks {
        let outcomes = rollup.map(outcome)
        let state = outcomes.isEmpty ? "none" : outcomes.contains("failed") ? "failing" : outcomes.contains("pending") ? "pending" : "passing"
        return Checks(state: state, passed: outcomes.filter { $0 == "passed" }.count, total: outcomes.count)
    }

    /// One check's outcome: `passed`, `failed` or `pending`.
    static func outcome(_ check: [String: Any]) -> String {
        let status = (check["status"] as? String)?.uppercased()
        let conclusion = ((check["conclusion"] as? String) ?? (check["state"] as? String) ?? "").uppercased()
        if let status, status != "COMPLETED" { return "pending" }
        switch conclusion {
        case "SUCCESS", "SKIPPED", "NEUTRAL": return "passed"
        // A stale check run was superseded by one not reported yet, as `gh pr checks` reads it.
        case "PENDING", "EXPECTED", "STALE", "": return "pending"
        default: return "failed"
        }
    }

    var json: JSONValue {
        ["url": .string(url), "number": JSONValue(number), "title": .string(title), "state": .string(state),
         "review": .string(review), "mergeable": .string(mergeable),
         "createdAt": .string(createdAt), "mergedAt": .string(mergedAt),
         "checks": ["state": .string(checks.state), "passed": JSONValue(checks.passed), "total": JSONValue(checks.total)],
         "checkList": .array(checkList.map { check in
             var row: [String: JSONValue] = ["name": .string(check.name), "state": .string(check.state)]
             if let url = check.url { row["url"] = .string(url) }
             return .object(row)
         })]
    }
}
