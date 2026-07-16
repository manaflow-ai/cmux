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

    /// Creates a presentation state from a GitHub check-run conclusion or status-context state.
    /// - Parameter githubState: The raw state returned by GitHub.
    init(githubState: String) {
        switch githubState.uppercased() {
        case "SUCCESS":
            self = .success
        case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE":
            self = .failure
        case "PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "STALE":
            self = .pending
        default:
            self = .neutral
        }
    }
}
