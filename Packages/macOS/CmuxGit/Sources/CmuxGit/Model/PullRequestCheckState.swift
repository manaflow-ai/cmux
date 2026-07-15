import Foundation

/// The presentation state derived from a `gh pr checks` state value.
public enum PullRequestCheckState: Equatable, Sendable {
    /// The check completed successfully.
    case success
    /// The check failed or requires action.
    case failure
    /// The check has not completed or GitHub marked its result stale.
    case pending
    /// The check completed without a success or failure conclusion.
    case neutral

    /// Normalizes GitHub check-run conclusions and status-context states.
    static func derive(from rawState: String) -> PullRequestCheckState {
        switch rawState.uppercased() {
        case "SUCCESS":
            return .success
        case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE":
            return .failure
        case "PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "STALE":
            return .pending
        default:
            return .neutral
        }
    }
}
