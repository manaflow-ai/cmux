/// The state GitHub reports for one commit check run.
public enum PullRequestCheckStatus: String, Sendable, Equatable {
    /// The check completed successfully.
    case success
    /// The check failed, was cancelled, or requires action.
    case failure
    /// The check is queued, waiting, or running.
    case pending
    /// The check was skipped or completed without a pass/fail result.
    case neutral
    /// Checks could not be fully fetched; never presented as success.
    case unavailable

    /// Normalizes a GitHub check run; unknown terminal results remain unavailable.
    public init(checkRunStatus: String, conclusion: String?) {
        guard checkRunStatus.lowercased() == "completed" else { self = .pending; return }
        switch conclusion?.lowercased() {
        case "success": self = .success
        case "neutral", "skipped": self = .neutral
        case "failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale": self = .failure
        default: self = .unavailable
        }
    }
}
