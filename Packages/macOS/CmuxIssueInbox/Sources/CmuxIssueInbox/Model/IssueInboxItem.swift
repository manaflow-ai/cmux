public import Foundation

/// A provider-neutral issue row shown by Issue Inbox.
public struct IssueInboxItem: Codable, Equatable, Sendable, Identifiable {
    /// Stable issue identifier, such as `github:manaflow-ai/cmux:123`.
    public var id: String
    /// Provider that supplied the item.
    public var provider: IssueProviderKind
    /// Browser URL for the provider issue.
    public var sourceURL: URL
    /// Issue title.
    public var title: String
    /// Normalized open or closed state.
    public var status: IssueStatus
    /// Provider-specific state value, when available.
    public var providerState: String?
    /// Provider update timestamp.
    public var updatedAt: Date
    /// GitHub `owner/repo` or Linear team key.
    public var repoOrProject: String
    /// GitHub issue number or Linear identifier.
    public var number: String
    /// Display assignee names.
    public var assignees: [String]
    /// Display label names.
    public var labels: [String]

    /// Stable identifier for the configured source that owns this item.
    public var sourceID: String {
        "\(provider.rawValue):\(repoOrProject)"
    }

    /// Creates a normalized issue inbox item.
    ///
    /// - Parameters:
    ///   - id: Stable issue identifier.
    ///   - provider: Provider that supplied the item.
    ///   - sourceURL: Browser URL for the provider issue.
    ///   - title: Issue title.
    ///   - status: Normalized open or closed state.
    ///   - providerState: Provider-specific state value, when available.
    ///   - updatedAt: Provider update timestamp.
    ///   - repoOrProject: GitHub `owner/repo` or Linear team key.
    ///   - number: GitHub issue number or Linear identifier.
    ///   - assignees: Display assignee names.
    ///   - labels: Display label names.
    public init(
        id: String,
        provider: IssueProviderKind,
        sourceURL: URL,
        title: String,
        status: IssueStatus,
        providerState: String? = nil,
        updatedAt: Date,
        repoOrProject: String,
        number: String,
        assignees: [String] = [],
        labels: [String] = []
    ) {
        self.id = id
        self.provider = provider
        self.sourceURL = sourceURL
        self.title = title
        self.status = status
        self.providerState = providerState
        self.updatedAt = updatedAt
        self.repoOrProject = repoOrProject
        self.number = number
        self.assignees = assignees
        self.labels = labels
    }
}
