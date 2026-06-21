public import Foundation

/// One existing-workspace destination the "Move Tab To…" context-menu submenu
/// can target, as seen by ``WorkspaceContextMenuCoordinator``.
///
/// A package-side value projection of the app-target `AppDelegate.WorkspaceMoveTarget`,
/// carrying only the two fields the move-destination list needs: the target
/// workspace's id (encoded into the bonsplit destination id) and the label shown
/// in the menu. The coordinator does not need the window id, tab manager, or
/// current-window flag the app-target type also holds.
public struct WorkspaceContextMoveTarget: Identifiable, Sendable, Equatable {
    /// The destination workspace's identifier.
    public let workspaceId: UUID
    /// The localized menu label for the destination workspace.
    public let label: String

    public var id: UUID { workspaceId }

    /// Creates a move target from its destination workspace id and menu label.
    public init(workspaceId: UUID, label: String) {
        self.workspaceId = workspaceId
        self.label = label
    }
}
