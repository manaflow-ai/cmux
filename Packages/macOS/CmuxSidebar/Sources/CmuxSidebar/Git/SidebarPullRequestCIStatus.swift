/// CI rollup status shown beside an open pull-request row.
public enum SidebarPullRequestCIStatus: String, Sendable, Equatable {
    /// Checks are absent, pending, in progress, or unavailable.
    case neutral
    /// Checks passed.
    case success
    /// Checks failed or errored.
    case failure
}
