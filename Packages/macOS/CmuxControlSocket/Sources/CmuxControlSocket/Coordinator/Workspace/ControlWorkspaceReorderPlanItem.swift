public import Foundation

/// One workspace's move in a reorder plan, mirroring the app's
/// `WorkspaceReorderPlanItem` for `workspace.reorder` / `workspace.reorder_many`.
///
/// The coordinator turns each item into the legacy
/// `v2WorkspaceReorderPlanPayload` row, minting the workspace/window refs.
public struct ControlWorkspaceReorderPlanItem: Sendable, Equatable {
    /// The workspace being moved.
    public let workspaceID: UUID
    /// The workspace's index before the move.
    public let fromIndex: Int
    /// The workspace's index after the move.
    public let toIndex: Int

    /// Creates a reorder plan item.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace being moved.
    ///   - fromIndex: The index before the move.
    ///   - toIndex: The index after the move.
    public init(workspaceID: UUID, fromIndex: Int, toIndex: Int) {
        self.workspaceID = workspaceID
        self.fromIndex = fromIndex
        self.toIndex = toIndex
    }
}
