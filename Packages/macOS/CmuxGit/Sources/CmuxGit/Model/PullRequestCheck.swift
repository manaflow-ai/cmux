public import Foundation

/// A single GitHub check shown in the PR hover detail.
public struct PullRequestCheck: Sendable, Equatable, Identifiable {
    /// Stable identity within this PR, including the check source.
    public let id: String
    /// Provider-supplied check name displayed verbatim.
    public let name: String
    /// Normalized result for the individual check.
    public let status: PullRequestCheckStatus
    /// The provider’s details page, when available.
    public let detailsURL: URL?

    /// Creates a value for one provider check; a missing URL means no details link.
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

