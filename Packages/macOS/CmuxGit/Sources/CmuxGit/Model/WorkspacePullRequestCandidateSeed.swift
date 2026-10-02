public import Foundation

/// The caller-provided input for one pull-request lookup: which workspace
/// panel wants a badge, for which branch, rooted at which directory.
public struct WorkspacePullRequestCandidateSeed: Sendable {
    /// Correlation id of the owning workspace.
    public let workspaceId: UUID
    /// Correlation id of the owning panel.
    public let panelId: UUID
    /// The (normalized) branch to look up.
    public let branch: String
    /// The panel's working directory, used to resolve GitHub remotes; `nil`
    /// when unknown.
    public let directory: String?

    /// Creates a candidate seed.
    public init(workspaceId: UUID, panelId: UUID, branch: String, directory: String?) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.branch = branch
        self.directory = directory
    }
}
