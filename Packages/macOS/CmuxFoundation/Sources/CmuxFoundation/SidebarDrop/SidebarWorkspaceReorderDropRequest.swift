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

    /// Where the drag currently previews, for resolving slots that are
    /// ambiguous between a group's tail and the root level (the last-member
    /// boundary): a drag already inside the group stays in it until it
    /// clearly leaves, a top-level drag stays out until it clearly enters.
    /// `.none` falls back to the pointer-lane heuristic.
    public let stickyDestination: SidebarWorkspaceReorderStickyDestination

    /// Creates input for the sidebar workspace reorder resolver.
    ///
    /// - Parameters:
    ///   - point: Pointer location in the drop overlay's coordinate space.
    ///   - draggedWorkspaceId: The workspace being dragged.
    ///   - foreignDraggedIsPinned: Pin state for a workspace dragged from another window.
    ///   - workspaces: Workspaces in the destination sidebar's raw storage order.
    ///   - groups: Workspace groups in the destination sidebar.
    ///   - targets: Visible row targets in the drop overlay's coordinate space.
    ///   - stickyDestination: Where the drag currently previews, for
    ///     resolving group/root-ambiguous boundary slots.
    public init(
        point: CGPoint,
        draggedWorkspaceId: UUID,
        foreignDraggedIsPinned: Bool? = nil,
        workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot],
        groups: [SidebarWorkspaceReorderGroupSnapshot],
        targets: [SidebarWorkspaceReorderDropTarget],
        stickyDestination: SidebarWorkspaceReorderStickyDestination = .none
    ) {
        self.point = point
        self.draggedWorkspaceId = draggedWorkspaceId
        self.foreignDraggedIsPinned = foreignDraggedIsPinned
        self.workspaces = workspaces
        self.groups = groups
        self.targets = targets
        self.stickyDestination = stickyDestination
    }
}

/// Where a live drag currently previews, used to resolve group/root-ambiguous
/// boundary slots in its favor.
public enum SidebarWorkspaceReorderStickyDestination: Equatable, Sendable {
    /// No live preview (indicator-line paths): use the pointer-lane heuristic.
    case none

    /// The drag currently previews a top-level slot.
    case topLevel

    /// The drag currently previews inside this group.
    case group(UUID)
}
