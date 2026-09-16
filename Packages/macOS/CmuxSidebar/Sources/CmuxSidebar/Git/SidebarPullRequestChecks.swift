/// PR check summary rendered beside the lifecycle badge.
public struct SidebarPullRequestChecks: Sendable, Equatable {
    public enum MergeStatus: String, Sendable, Equatable {
        case ready
        case blocked
        case conflict
        case unknown
    }

    public let status: SidebarPullRequestCheckStatus
    public let checks: [SidebarPullRequestCheck]
    public let mergeStatus: MergeStatus

    public init(
        status: SidebarPullRequestCheckStatus,
        checks: [SidebarPullRequestCheck],
        mergeStatus: MergeStatus
    ) {
        self.status = status
        self.checks = checks
        self.mergeStatus = mergeStatus
    }
}
