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
    /// Whether the directory's checked-out branch could not be verified
    /// (repository present but `HEAD` unreadable/malformed). Such a candidate
    /// resolves as a transient failure so an existing badge is kept rather
    /// than re-matched against a possibly stale projected branch.
    public let branchReadFailed: Bool

    /// Creates a resolved candidate.
    public init(
        workspaceId: UUID,
        panelId: UUID,
        branch: String,
        repoSlugs: [String],
        branchReadFailed: Bool = false
    ) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.branch = branch
        self.repoSlugs = repoSlugs
        self.branchReadFailed = branchReadFailed
    }
}
