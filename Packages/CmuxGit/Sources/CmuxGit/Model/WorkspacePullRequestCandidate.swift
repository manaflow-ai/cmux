public import Foundation

/// A seed resolved against repository remotes: the lookup the fetch stage executes.
public struct WorkspacePullRequestCandidate: Sendable {
    /// Correlation id of the owning workspace.
    public let workspaceId: UUID
    /// Correlation id of the owning panel.
    public let panelId: UUID
    /// The branch to match pull requests against.
    public let branch: String
    /// Host-qualified repository references to search, in preference order.
    public let repoReferences: [GitHubRepositoryReference]

    /// Creates a resolved candidate.
    ///
    /// - Parameters:
    ///   - workspaceId: Correlation id of the owning workspace.
    ///   - panelId: Correlation id of the owning panel.
    ///   - branch: The branch to match pull requests against.
    ///   - repoReferences: Host-qualified repositories to query.
    public init(
        workspaceId: UUID,
        panelId: UUID,
        branch: String,
        repoReferences: [GitHubRepositoryReference]
    ) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.branch = branch
        self.repoReferences = repoReferences
    }
}
