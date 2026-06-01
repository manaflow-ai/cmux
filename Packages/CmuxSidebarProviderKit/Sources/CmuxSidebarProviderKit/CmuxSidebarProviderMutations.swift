import Foundation

/// Presentation command a provider can request from the CMUX sidebar host.
public enum CmuxSidebarProviderPresentationRequest: Codable, Equatable, Sendable {
    /// Open the workspace popover on a preferred tab.
    case openWorkspacePopover(workspaceId: UUID, preferredTab: CmuxSidebarProviderWorkspacePopoverTab)
    /// Open a detached workspace window on a preferred tab.
    case openWorkspaceWindow(workspaceId: UUID, preferredTab: CmuxSidebarProviderWorkspacePopoverTab)
    /// Ask CMUX to open a URL.
    case openURL(String)
}

/// Drag-and-drop move request for a workspace row.
public struct CmuxSidebarProviderWorkspaceMove: Codable, Equatable, Sendable {
    /// Workspace being moved.
    public var workspaceId: UUID
    /// Source section id, if known.
    public var sourceSectionId: String?
    /// Destination section id.
    public var targetSectionId: String
    /// Destination row index inside the target section.
    public var targetIndex: Int

    /// Creates a workspace move request.
    public init(
        workspaceId: UUID,
        sourceSectionId: String?,
        targetSectionId: String,
        targetIndex: Int
    ) {
        self.workspaceId = workspaceId
        self.sourceSectionId = sourceSectionId
        self.targetSectionId = targetSectionId
        self.targetIndex = targetIndex
    }
}

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

/// Result returned after CMUX handles a provider mutation.
public struct CmuxSidebarProviderCommandResult: Codable, Equatable, Sendable {
    /// Whether CMUX accepted and completed the command.
    public var ok: Bool

    /// Creates a command result.
    public init(ok: Bool) {
        self.ok = ok
    }
}

/// Provider that can both render sidebar state and handle host mutations.
public protocol CmuxMutableSidebarProvider: CmuxContextualSidebarProvider {
    /// Handles a mutation against the latest sidebar snapshot.
    func handle(
        _ mutation: CmuxSidebarProviderMutation,
        snapshot: CmuxSidebarProviderSnapshot
    ) throws -> CmuxSidebarProviderCommandResult
}
