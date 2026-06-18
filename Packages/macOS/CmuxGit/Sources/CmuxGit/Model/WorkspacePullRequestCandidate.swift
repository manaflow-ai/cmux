public import Foundation

/// A seed resolved against the repository's GitHub remotes: the lookup the
/// fetch stage executes.
public struct WorkspacePullRequestCandidate: Sendable {
    /// Correlation id of the owning workspace.
    public let workspaceId: UUID
    /// Correlation id of the owning panel.
    public let panelId: UUID
    /// The branch to match pull requests against.
    public let branch: String
    /// GitHub `owner/name` slugs to search, in preference order; empty when the
    /// directory has no GitHub remote (an unsupported repository).
    public let repoSlugs: [String]

    /// Creates a resolved candidate.
    public init(workspaceId: UUID, panelId: UUID, branch: String, repoSlugs: [String]) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.branch = branch
        self.repoSlugs = repoSlugs
    }
}
