/// The state GitHub reports for one commit check run.
public enum PullRequestCheckStatus: String, Sendable, Equatable {
    case success
    case failure
    case pending
    case neutral
    /// Checks could not be fully fetched; never presented as success.
    case unavailable
}

