public import CoreGraphics
public import Foundation

/// A visible workspace sidebar row that can participate in reorder hit testing.
public struct SidebarWorkspaceReorderDropTarget: Equatable, Sendable {
    /// The workspace represented by the visible row.
    public let workspaceId: UUID

    /// The workspace group represented by or containing the row, if any.
    public let groupId: UUID?

    /// Whether the row is a workspace group header.
    public let isGroupHeader: Bool

    /// The row frame in the drop overlay's coordinate space.
    public let frame: CGRect

    /// Creates a visible row target for sidebar reorder planning.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace represented by the visible row.
    ///   - groupId: The workspace group represented by or containing the row, if any.
    ///   - isGroupHeader: Whether the row is a workspace group header.
    ///   - frame: The row frame in the drop overlay's coordinate space.
    public init(workspaceId: UUID, groupId: UUID?, isGroupHeader: Bool, frame: CGRect) {
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.isGroupHeader = isGroupHeader
        self.frame = frame
    }
}
