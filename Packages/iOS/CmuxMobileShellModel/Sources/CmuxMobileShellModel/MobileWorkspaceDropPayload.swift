import Foundation

/// The identity carried by a mobile workspace drag session.
public struct MobileWorkspaceDropPayload: Codable, Equatable, Sendable {
    /// The dragged workspace, or a dragged group's anchor workspace.
    public let workspaceID: MobileWorkspacePreview.ID
    /// Whether the anchor represents a whole-group drag.
    public let isGroupDrag: Bool

    /// Creates a workspace drag payload.
    /// - Parameters:
    ///   - workspaceID: The dragged workspace or group anchor identity.
    ///   - isGroupDrag: Whether the drag moves the anchor's whole group.
    public init(workspaceID: MobileWorkspacePreview.ID, isGroupDrag: Bool) {
        self.workspaceID = workspaceID
        self.isGroupDrag = isGroupDrag
    }
}
