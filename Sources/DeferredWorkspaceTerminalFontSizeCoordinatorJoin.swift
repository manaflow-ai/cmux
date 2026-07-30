import Foundation

/// An event that joins two independently busy coordinators and waits until
/// either prior owner becomes available.
struct DeferredWorkspaceTerminalFontSizeCoordinatorJoin {
    let workspaceId: UUID
    let workspaceReference:
        WorkspaceTerminalFontSizeCoordinator.WeakWorkspaceReference
    let windowDockSlot:
        WorkspaceTerminalFontSizeCoordinator.WindowDockSlot
    let preferredCoordinator:
        WorkspaceTerminalFontSizeCoordinator
    let acceptedOrder: UInt64
    let projectionToken: UUID
    var includesWindowDock: Bool
    var change: WorkspaceTerminalFontSizeChange
    var deferFlush: Bool

    func matches(
        workspace: Workspace,
        windowDockSlot:
            WorkspaceTerminalFontSizeCoordinator.WindowDockSlot,
        includesWindowDock: Bool
    ) -> Bool {
        workspaceId == workspace.id
            && workspaceReference.value === workspace
            && self.windowDockSlot === windowDockSlot
            && self.includesWindowDock == includesWindowDock
    }
}
