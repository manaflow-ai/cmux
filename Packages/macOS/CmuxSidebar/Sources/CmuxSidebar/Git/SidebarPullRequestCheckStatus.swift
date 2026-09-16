/// Compact status states for the optional PR checks indicator.
public enum SidebarPullRequestCheckStatus: String, Sendable, Equatable {
    case success
    case failure
    case pending
    case neutral
    /// Checks could not be fully fetched; never presented as success.
    case unavailable
}

