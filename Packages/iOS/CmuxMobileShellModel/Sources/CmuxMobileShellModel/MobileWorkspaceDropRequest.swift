public import CoreGraphics
import Foundation

/// The immutable input snapshot for point-aware workspace drop resolution.
public struct MobileWorkspaceDropRequest: Sendable {
    /// The dragged workspace or group anchor.
    public let payload: MobileWorkspaceDropPayload
    /// Visible rows and their list-space frames.
    public let rows: [MobileWorkspaceDropRowFrame]
    /// Current workspace ordering and membership.
    public let workspaces: [MobileWorkspacePreview]
    /// Current group metadata.
    public let groups: [MobileWorkspaceGroupPreview]
    /// The finger location in list coordinates.
    public let point: CGPoint
    /// The horizontal boundary between root and in-group lanes.
    public let listMidlineX: CGFloat

    /// Creates a point-aware drop request.
    /// - Parameters:
    ///   - payload: The dragged workspace or group anchor.
    ///   - rows: Visible row-frame snapshots.
    ///   - workspaces: Current workspace ordering and membership.
    ///   - groups: Current group metadata.
    ///   - point: The finger location in list coordinates.
    ///   - listMidlineX: The root/group lane boundary.
    public init(
        payload: MobileWorkspaceDropPayload,
        rows: [MobileWorkspaceDropRowFrame],
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        point: CGPoint,
        listMidlineX: CGFloat
    ) {
        self.payload = payload
        self.rows = rows
        self.workspaces = workspaces
        self.groups = groups
        self.point = point
        self.listMidlineX = listMidlineX
    }
}
