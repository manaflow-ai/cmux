public import Foundation

/// A single GitHub check shown in the PR hover detail.
public struct PullRequestCheck: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let status: PullRequestCheckStatus
    public let detailsURL: URL?

    public init(
        id: String,
        name: String,
        status: PullRequestCheckStatus,
        detailsURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.detailsURL = detailsURL
    }
}

