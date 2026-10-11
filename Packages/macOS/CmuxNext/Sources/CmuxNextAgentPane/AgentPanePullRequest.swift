import CmuxNextSettings
public import Foundation

/// The pull request of a chat folder's branch, as the chat header's chip shows it (cx-tcwj, Codex
/// desktop's PR chip): read from `gh pr view --json url,number,state,isDraft,statusCheckRollup`.
public nonisolated struct AgentPanePullRequest: Equatable, Sendable {
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
    /// `open`, `draft`, `merged` or `closed`.
    public var state: String
    public var checks: Checks

    public init(url: String, number: Int, state: String, checks: Checks) {
        self.url = url
        self.number = number
        self.state = state
        self.checks = checks
    }

    /// Nil unless `ghView` is gh's answer with an https url and a number.
    public init?(ghView: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: ghView) as? [String: Any],
              let url = object["url"] as? String, url.hasPrefix("https://"), !url.contains(where: \.isWhitespace),
              let number = object["number"] as? Int else { return nil }
        let state = (object["state"] as? String)?.lowercased() ?? "open"
        self.init(url: url, number: number, state: state == "open" && object["isDraft"] as? Bool == true ? "draft" : state,
                  checks: Self.checks(object["statusCheckRollup"] as? [[String: Any]] ?? []))
    }

    /// A check run (`status`, `conclusion`) or a commit status (`state`), each as passed, failed or
    /// still running.
    static func checks(_ rollup: [[String: Any]]) -> Checks {
        let outcomes = rollup.map { check -> String in
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
        let state = outcomes.isEmpty ? "none" : outcomes.contains("failed") ? "failing" : outcomes.contains("pending") ? "pending" : "passing"
        return Checks(state: state, passed: outcomes.filter { $0 == "passed" }.count, total: outcomes.count)
    }

    var json: JSONValue {
        ["url": .string(url), "number": JSONValue(number), "state": .string(state),
         "checks": ["state": .string(checks.state), "passed": JSONValue(checks.passed), "total": JSONValue(checks.total)]]
    }
}
