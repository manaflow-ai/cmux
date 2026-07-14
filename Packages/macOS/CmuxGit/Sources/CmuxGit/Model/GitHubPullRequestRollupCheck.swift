import Foundation

/// A check-run or status-context entry returned in `gh pr view`'s `statusCheckRollup` field.
struct GitHubPullRequestRollupCheck: Decodable, Equatable, Sendable {
    /// The lifecycle status, such as `COMPLETED` or `IN_PROGRESS`.
    let status: String?

    /// The terminal conclusion, such as `SUCCESS`, `FAILURE`, or `ACTION_REQUIRED`.
    let conclusion: String?

    /// The terminal status-context state when this rollup entry is not a check run.
    let state: String?

    /// The conclusion used for rollup derivation across GitHub's check-run and status-context payloads.
    var effectiveConclusion: String? {
        conclusion ?? state
    }

    /// Whether GitHub reports this entry as complete.
    var isCompleted: Bool {
        if let status {
            return status.uppercased() == "COMPLETED"
        }
        guard let state = state?.uppercased() else { return false }
        return state != "PENDING" && state != "EXPECTED"
    }

    /// Creates a check-rollup entry.
    /// - Parameters:
    ///   - status: The lifecycle status.
    ///   - conclusion: The terminal conclusion.
    ///   - state: The terminal status-context state.
    init(status: String?, conclusion: String?, state: String? = nil) {
        self.status = status
        self.conclusion = conclusion
        self.state = state
    }
}
