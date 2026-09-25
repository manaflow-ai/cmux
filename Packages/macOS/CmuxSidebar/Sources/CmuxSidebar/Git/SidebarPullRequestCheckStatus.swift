/// Compact status states for the optional PR checks indicator.
public enum SidebarPullRequestCheckStatus: String, Sendable, Equatable {
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
}
