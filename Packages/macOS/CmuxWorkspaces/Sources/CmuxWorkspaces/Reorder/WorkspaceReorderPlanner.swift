public import Foundation

/// Pure batch-reorder planning over a snapshot of the window's tab order,
/// lifted one-for-one from the app-side `TabManager.workspaceBatchReorderPlan`
/// and `batchWorkspaceReorderFinalIds`: validates the request, then computes
/// the final id order with the pinned-ahead-of-unpinned invariant and stable
/// ordering for workspaces the request does not mention.
///
/// Stateless and `Sendable`; the window owns one as a plain value. Applying
/// the plan (rebuilding tabs, renormalizing group sections, posting order
/// notifications) stays with the owner.
public struct WorkspaceReorderPlanner: Sendable {
    /// Creates the stateless planner.
    public init() {}

    /// Validates `orderedWorkspaceIds` against `current` and returns the
    /// per-workspace move plan, or the first validation failure (duplicate
    /// entry, then unknown workspace).
    public func batchReorderPlan(
        orderedWorkspaceIds: [UUID],
        current: [WorkspaceOrderSnapshot]
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        var seen = Set<UUID>()
        for workspaceId in orderedWorkspaceIds {
            guard seen.insert(workspaceId).inserted else {
                return .failure(.duplicateWorkspace(workspaceId))
            }
        }

        let currentIndexes = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($0.element.id, $0.offset) })
        for workspaceId in orderedWorkspaceIds where currentIndexes[workspaceId] == nil {
            return .failure(.workspaceNotFound(workspaceId))
        }

        let finalIds = batchReorderFinalIds(orderedWorkspaceIds: orderedWorkspaceIds, current: current)
        let finalIndexes = Dictionary(uniqueKeysWithValues: finalIds.enumerated().map { ($0.element, $0.offset) })

        let plan = orderedWorkspaceIds.map { workspaceId in
            WorkspaceReorderPlanItem(
                workspaceId: workspaceId,
                fromIndex: currentIndexes[workspaceId] ?? 0,
                toIndex: finalIndexes[workspaceId] ?? 0
            )
        }
        return .success(plan)
    }

    /// Computes the full final id order for the batch reorder: requested
    /// pinned ids, remaining pinned ids in current order, requested unpinned
    /// ids, remaining unpinned ids in current order.
    public func batchReorderFinalIds(
        orderedWorkspaceIds: [UUID],
        current: [WorkspaceOrderSnapshot]
    ) -> [UUID] {
        let orderedSet = Set(orderedWorkspaceIds)
        let snapshotsById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let orderedPinnedIds = orderedWorkspaceIds.filter { snapshotsById[$0]?.isPinned == true }
        let orderedUnpinnedIds = orderedWorkspaceIds.filter { snapshotsById[$0]?.isPinned == false }
        let remainingPinnedIds = current
            .map(\.id)
            .filter { !orderedSet.contains($0) && snapshotsById[$0]?.isPinned == true }
        let remainingUnpinnedIds = current
            .map(\.id)
            .filter { !orderedSet.contains($0) && snapshotsById[$0]?.isPinned == false }
        return orderedPinnedIds + remainingPinnedIds + orderedUnpinnedIds + remainingUnpinnedIds
    }
}
