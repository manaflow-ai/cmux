/// PR check summary rendered beside the lifecycle badge.
public struct SidebarPullRequestChecks: Sendable, Equatable {

    /// Aggregate check outcome; unavailable data never implies success.
    public let status: SidebarPullRequestCheckStatus
    /// Individual check results included in this summary.
    public let checks: [SidebarPullRequestCheck]
    /// Merge conflicts or other blockers, independent of check results.
    public let mergeStatus: SidebarPullRequestMergeStatus

    /// Creates a summary with separate CI and mergeability outcomes.
    public init(
        status: SidebarPullRequestCheckStatus,
        checks: [SidebarPullRequestCheck],
        mergeStatus: SidebarPullRequestMergeStatus
    ) {
        self.status = status
        self.checks = checks
        self.mergeStatus = mergeStatus
    }
}
