public import Foundation

/// One planned workspace move: where the workspace sits now and where the
/// reorder will place it.
public struct WorkspaceReorderPlanItem: Equatable, Sendable {
    /// The workspace being moved.
    public let workspaceId: UUID
    /// The workspace's current index.
    public let fromIndex: Int
    /// The index the reorder will place it at.
    public let toIndex: Int

    /// Creates a plan item.
    public init(workspaceId: UUID, fromIndex: Int, toIndex: Int) {
        self.workspaceId = workspaceId
        self.fromIndex = fromIndex
        self.toIndex = toIndex
    }
}
