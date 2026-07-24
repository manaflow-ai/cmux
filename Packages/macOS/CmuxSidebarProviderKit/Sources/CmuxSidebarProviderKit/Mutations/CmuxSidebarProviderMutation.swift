import Foundation

/// Host mutation requested by an in-process sidebar provider.
public enum CmuxSidebarProviderMutation: Codable, Equatable, Sendable {
    /// Select a workspace.
    case selectWorkspace(UUID)
    /// Close a workspace.
    case closeWorkspace(UUID)
    /// Create a worktree rooted at a project path.
    case createWorktree(projectRootPath: String)
    /// Move a workspace row.
    case moveWorkspace(CmuxSidebarProviderWorkspaceMove)
    /// Present host UI or a URL.
    case present(CmuxSidebarProviderPresentationRequest)
}
