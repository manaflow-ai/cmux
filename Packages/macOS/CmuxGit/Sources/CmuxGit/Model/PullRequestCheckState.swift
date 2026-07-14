import Foundation

/// The presentation state derived from a `gh pr checks` state value.
public enum PullRequestCheckState: Equatable, Sendable {
    /// The check completed successfully.
    case success
    /// The check failed or requires action.
    case failure
    /// The check has not completed.
    case pending
    /// The check completed without a success or failure conclusion.
    case neutral
}
