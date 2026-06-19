public import Foundation

/// Pure planner for the closed-panel-history workspace-id remaps a restore
/// requires.
///
/// Session restore and window restore both rewrite closed-panel history from
/// each pre-restore workspace id to its freshly minted post-restore id, but
/// they differ in one detail: session restore carries optional original ids
/// and skips any workspace whose id did not actually change, while window
/// restore carries required original ids and remaps every aligned pair. This
/// type captures that planning as two pure functions over value types; the app
/// shell feeds the post-restore workspace ids plus the per-index panel-id maps,
/// receives the ordered ``ClosedPanelHistoryRemapOperation`` list, applies each
/// to its closed-item history store, and flushes once when the list is
/// non-empty. The planner reads no live `Workspace` objects and touches no
/// store.
///
/// Isolation: a stateless `Sendable` struct held by the app shell, constructed
/// at the composition root. No mutable state, so no actor or lock.
public struct ClosedPanelHistoryRemapPlanner: Sendable {
    /// Creates the planner. It holds no dependencies; the explicit initializer
    /// keeps the type a real injected instance rather than a static-method
    /// namespace.
    public init() {}

    /// Plans the remaps for a session-snapshot restore.
    ///
    /// Mirrors the legacy `remapClosedPanelHistoryAfterSessionRestore`
    /// byte-for-byte: it walks the aligned prefix
    /// (`min(originalWorkspaceIds.count, restoredWorkspaceIds.count)`), skips
    /// entries whose original id is nil or already equal to the restored id
    /// (no rotation happened), and emits a remap for the rest. An empty result
    /// means the caller does not flush, matching the legacy
    /// `didRequestHistoryRemap` gate.
    ///
    /// - Parameters:
    ///   - originalWorkspaceIds: Pre-restore ids per restored slot; nil where
    ///     the original id is unknown.
    ///   - restoredWorkspaceIds: Post-restore ids in restored tab order.
    ///   - panelIdMapsByIndex: Per-slot old-to-new panel id maps; an absent or
    ///     short entry yields an empty map for that slot.
    /// - Returns: The ordered remap operations (possibly empty).
    public func planSessionRestoreRemaps(
        originalWorkspaceIds: [UUID?],
        restoredWorkspaceIds: [UUID],
        panelIdMapsByIndex: [[UUID: UUID]]
    ) -> [ClosedPanelHistoryRemapOperation] {
        let count = min(originalWorkspaceIds.count, restoredWorkspaceIds.count)
        guard count > 0 else { return [] }
        var operations: [ClosedPanelHistoryRemapOperation] = []
        for index in 0..<count {
            guard let originalWorkspaceId = originalWorkspaceIds[index],
                  originalWorkspaceId != restoredWorkspaceIds[index] else {
                continue
            }
            let panelIdMap = panelIdMapsByIndex.indices.contains(index)
                ? panelIdMapsByIndex[index]
                : [:]
            operations.append(
                ClosedPanelHistoryRemapOperation(
                    fromWorkspaceId: originalWorkspaceId,
                    toWorkspaceId: restoredWorkspaceIds[index],
                    panelIdMap: panelIdMap
                )
            )
        }
        return operations
    }

    /// Plans the remaps for a window restore.
    ///
    /// Mirrors the legacy `remapClosedPanelHistoryAfterWindowRestore`
    /// byte-for-byte: it returns empty when there are no original ids, then
    /// walks the aligned prefix and emits a remap for every slot (window
    /// restore always rotates the workspace id, so there is no skip). An empty
    /// result means the caller does not flush.
    ///
    /// - Parameters:
    ///   - originalWorkspaceIds: Pre-restore ids in restored tab order.
    ///   - restoredWorkspaceIds: Post-restore ids in restored tab order.
    ///   - panelIdMapsByIndex: Per-slot old-to-new panel id maps; an absent or
    ///     short entry yields an empty map for that slot.
    /// - Returns: The ordered remap operations (possibly empty).
    public func planWindowRestoreRemaps(
        originalWorkspaceIds: [UUID],
        restoredWorkspaceIds: [UUID],
        panelIdMapsByIndex: [[UUID: UUID]]
    ) -> [ClosedPanelHistoryRemapOperation] {
        guard !originalWorkspaceIds.isEmpty else { return [] }
        let count = min(originalWorkspaceIds.count, restoredWorkspaceIds.count)
        guard count > 0 else { return [] }
        var operations: [ClosedPanelHistoryRemapOperation] = []
        for index in 0..<count {
            let panelIdMap = panelIdMapsByIndex.indices.contains(index)
                ? panelIdMapsByIndex[index]
                : [:]
            operations.append(
                ClosedPanelHistoryRemapOperation(
                    fromWorkspaceId: originalWorkspaceIds[index],
                    toWorkspaceId: restoredWorkspaceIds[index],
                    panelIdMap: panelIdMap
                )
            )
        }
        return operations
    }
}
