import Foundation

/// One workspace position and its drag-intended group membership.
public struct MobileWorkspaceOptimisticOrderEntry: Equatable, Sendable {
    /// The workspace identity retained across live snapshot refreshes.
    public let id: MobileWorkspacePreview.ID
    /// The membership predicted by the optimistic move.
    public let groupID: MobileWorkspaceGroupPreview.ID?
    /// The pin state the prediction was computed against. A Mac-side pin
    /// change alters legal ordering, so it invalidates the prediction.
    public let isPinned: Bool

    /// Creates an optimistic ordering entry.
    /// - Parameters:
    ///   - id: The workspace identity.
    ///   - groupID: The membership predicted by the move.
    ///   - isPinned: The pin state the prediction assumed.
    public init(
        id: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID?,
        isPinned: Bool
    ) {
        self.id = id
        self.groupID = groupID
        self.isPinned = isPinned
    }
}
