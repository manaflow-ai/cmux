import Foundation

/// Value projection of an app window shown by the workspace-row move menu.
struct SidebarWorkspaceWindowMoveTarget: Equatable, Identifiable {
    let windowId: UUID
    let label: String
    let isCurrentWindow: Bool

    var id: UUID { windowId }
}
