import Foundation

/// One workspace position and its drag-intended group membership.
public struct MobileWorkspaceOptimisticOrderEntry: Equatable, Sendable {
    /// The workspace identity retained across live snapshot refreshes.
    public let id: MobileWorkspacePreview.ID
    /// The membership predicted by the optimistic move.
    public let groupID: MobileWorkspaceGroupPreview.ID?

    /// Creates an optimistic ordering entry.
    /// - Parameters:
    ///   - id: The workspace identity.
    ///   - groupID: The membership predicted by the move.
    public init(id: MobileWorkspacePreview.ID, groupID: MobileWorkspaceGroupPreview.ID?) {
        self.id = id
        self.groupID = groupID
    }
}
