public import Foundation

/// One pull-request row shown under a workspace in the sidebar.
public struct SidebarPullRequestState: Equatable, Sendable {
    /// The PR number.
    public let number: Int
    /// The repository label (e.g. `owner/repo`).
    public let label: String
    /// The PR URL.
    public let url: URL
    /// Lifecycle status.
    public let status: SidebarPullRequestStatus
    /// The PR's branch, normalized (trimmed, nil when empty).
    public let branch: String?
    /// Whether the row is stale (reported by an inactive panel).
    public let isStale: Bool
    /// Rollup CI/check state for open PR rows.
    public let ciStatus: SidebarPullRequestCIStatus

    /// Creates a pull-request row (defaults mirror the legacy initializer).
    public init(
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        isStale: Bool = false,
        ciStatus: SidebarPullRequestCIStatus = .neutral
    ) {
        self.number = number
        self.label = label
        self.url = url
        self.status = status
        self.branch = branch?.normalizedSidebarBranchName
        self.isStale = isStale
        self.ciStatus = ciStatus
    }
}
