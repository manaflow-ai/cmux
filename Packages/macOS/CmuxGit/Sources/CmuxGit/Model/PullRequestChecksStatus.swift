import Foundation

/// The checks-section summary derived from GitHub's status-check rollup.
public enum PullRequestChecksStatus: Equatable, Sendable {
    /// No checks have been reported.
    case noChecks
    /// At least one check failed, errored, timed out, was cancelled, or requires action.
    case failure
    /// No check failed, but at least one check has not completed or has no conclusion.
    case pending
    /// At least one completed check succeeded and none failed or remained pending.
    case success
    /// All checks completed with neutral or skipped conclusions.
    case neutral

    /// Creates a summary by applying GitHub's rollup precedence to check-run and status-context values.
    /// - Parameter checks: The `statusCheckRollup` entries returned by `gh pr view`.
    init(checks: [GitHubPullRequestRollupCheck]) {
        guard !checks.isEmpty else {
            self = .noChecks
            return
        }

        var hasPending = false
        var hasSuccess = false
        for check in checks {
            guard check.isCompleted, let conclusion = check.effectiveConclusion else {
                hasPending = true
                continue
            }
            switch PullRequestCheckState(githubState: conclusion) {
            case .failure:
                self = .failure
                return
            case .pending:
                hasPending = true
            case .success:
                hasSuccess = true
            case .neutral:
                break
            }
        }

        if hasPending {
            self = .pending
        } else if hasSuccess {
            self = .success
        } else {
            self = .neutral
        }
    }
}
