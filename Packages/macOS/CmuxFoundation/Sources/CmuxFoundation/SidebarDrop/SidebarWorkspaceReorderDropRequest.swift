public import CoreGraphics
public import Foundation

/// Input snapshot for resolving a sidebar workspace reorder drop.
public struct SidebarWorkspaceReorderDropRequest: Equatable, Sendable {
    /// Pointer location in the drop overlay's coordinate space.
    public let point: CGPoint

    /// The workspace being dragged.
    public let draggedWorkspaceId: UUID

    /// Pin state for a workspace dragged from another window.
    public let foreignDraggedIsPinned: Bool?

    /// Workspaces in the destination sidebar's raw storage order.
    public let workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot]

    /// Workspace groups in the destination sidebar.
    public let groups: [SidebarWorkspaceReorderGroupSnapshot]

    /// Visible row targets in the drop overlay's coordinate space.
    public let targets: [SidebarWorkspaceReorderDropTarget]

    /// Creates input for the sidebar workspace reorder resolver.
    ///
    /// - Parameters:
    ///   - point: Pointer location in the drop overlay's coordinate space.
    ///   - draggedWorkspaceId: The workspace being dragged.
    ///   - foreignDraggedIsPinned: Pin state for a workspace dragged from another window.
    ///   - workspaces: Workspaces in the destination sidebar's raw storage order.
    ///   - groups: Workspace groups in the destination sidebar.
    ///   - targets: Visible row targets in the drop overlay's coordinate space.
    public init(
        point: CGPoint,
        draggedWorkspaceId: UUID,
        foreignDraggedIsPinned: Bool? = nil,
        workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot],
        groups: [SidebarWorkspaceReorderGroupSnapshot],
        targets: [SidebarWorkspaceReorderDropTarget]
    ) {
        self.point = point
        self.draggedWorkspaceId = draggedWorkspaceId
        self.foreignDraggedIsPinned = foreignDraggedIsPinned
        self.workspaces = workspaces
        self.groups = groups
        self.targets = targets
    }
}
