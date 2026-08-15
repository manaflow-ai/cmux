import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    enum RequestTarget {
        case workspace(
            id: UUID,
            reference: WeakWorkspaceReference
        )
        case windowDock(
            slot: WindowDockSlot,
            seedWorkspace: WeakWorkspaceReference?
        )
    }
}
