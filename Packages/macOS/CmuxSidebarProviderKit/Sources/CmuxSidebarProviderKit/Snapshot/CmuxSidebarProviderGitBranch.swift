import Foundation

/// Git branch state for a provider workspace.
public struct CmuxSidebarProviderGitBranch: Codable, Equatable, Sendable {
    /// Branch name.
    public var branch: String
    /// Whether the worktree has uncommitted changes.
    public var isDirty: Bool

    /// Creates git branch state.
    public init(branch: String, isDirty: Bool) {
        self.branch = branch
        self.isDirty = isDirty
    }
}
