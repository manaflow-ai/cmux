public import Foundation

/// One check listed in the PR hover detail.
public struct SidebarPullRequestCheck: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let status: SidebarPullRequestCheckStatus
    public let detailsURL: URL?

    public init(
        id: String,
        name: String,
        status: SidebarPullRequestCheckStatus,
        detailsURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.detailsURL = detailsURL
    }
}

