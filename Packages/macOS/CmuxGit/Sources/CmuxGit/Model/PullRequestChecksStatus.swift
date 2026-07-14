import Foundation

/// The checks-section summary derived from GitHub's status-check rollup.
public enum PullRequestChecksStatus: Equatable, Sendable {
    /// No checks have been reported.
    case noChecks
    /// At least one check failed, timed out, was cancelled, or requires action.
    case failure
    /// No check failed, but at least one check has not completed or has no conclusion.
    case pending
    /// At least one completed check succeeded and none failed or remained pending.
    case success
    /// All checks completed with neutral or skipped conclusions.
    case neutral

    /// Applies GitHub's rollup precedence to check-run and status-context values.
    /// - Parameter checks: The `statusCheckRollup` entries returned by `gh pr view`.
    /// - Returns: The overall check status.
    static func derive(from checks: [GitHubPullRequestRollupCheck]) -> PullRequestChecksStatus {
        guard !checks.isEmpty else { return .noChecks }

        let failureConclusions: Set<String> = [
            "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED",
        ]
        if checks.contains(where: { check in
            check.effectiveConclusion.map { failureConclusions.contains($0.uppercased()) } == true
        }) {
            return .failure
        }

        if checks.contains(where: { check in
            let conclusion = check.effectiveConclusion?.uppercased()
            return !check.isCompleted || conclusion == nil || conclusion == "PENDING"
        }) {
            return .pending
        }

        if checks.contains(where: { $0.effectiveConclusion?.uppercased() == "SUCCESS" }) {
            return .success
        }
        return .neutral
    }
}
