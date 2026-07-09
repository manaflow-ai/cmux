import Foundation

/// A pure, value-typed transform over the persisted closed-item history.
///
/// Each case describes one structural rewrite applied to
/// ``ClosedItemHistoryRecord`` values when workspaces, panels, or windows are
/// reidentified (after a restore remaps their UUIDs) or torn down. Applying a
/// mutation returns the rewritten records plus whether anything actually
/// changed, so callers can skip a revision bump and persistence on a no-op.
///
/// The store both queues these (to replay against records still loading from
/// disk) and applies one immediately against the in-memory records, so the
/// transform lives on the value that names the operation rather than on the
/// store. The per-case rewrites stay private static helpers of this type.
enum ClosedItemHistoryRecordMutation {
    case remapPanelWorkspaceIds(
        oldWorkspaceId: UUID,
        newWorkspaceId: UUID,
        panelIdMap: [UUID: UUID]
    )
    case remapPanelAnchorIds(oldPanelId: UUID, newPanelId: UUID)
    case remapWorkspaceWindowIds(oldWindowId: UUID, newWindowId: UUID)
    case removePanelRecords(workspaceIds: Set<UUID>)

    /// Applies this mutation to `records`, returning the rewritten list and
    /// whether it differs from the input.
    func apply(
        to records: [ClosedItemHistoryRecord]
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        switch self {
        case .remapPanelWorkspaceIds(let oldWorkspaceId, let newWorkspaceId, let panelIdMap):
            return Self.recordsByRemappingPanelWorkspaceIds(
                records,
                from: oldWorkspaceId,
                to: newWorkspaceId,
                panelIdMap: panelIdMap
            )
        case .remapPanelAnchorIds(let oldPanelId, let newPanelId):
            return Self.recordsByRemappingPanelAnchorIds(records, from: oldPanelId, to: newPanelId)
        case .remapWorkspaceWindowIds(let oldWindowId, let newWindowId):
            return Self.recordsByRemappingWorkspaceWindowIds(records, from: oldWindowId, to: newWindowId)
        case .removePanelRecords(let workspaceIds):
            return Self.recordsByRemovingPanelRecords(records, forWorkspaceIds: workspaceIds)
        }
    }

    private static func recordsByRemappingPanelWorkspaceIds(
        _ records: [ClosedItemHistoryRecord],
        from oldWorkspaceId: UUID,
        to newWorkspaceId: UUID,
        panelIdMap: [UUID: UUID]
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        func remapAnchor(_ panelId: UUID?) -> UUID? {
            guard let panelId else { return nil }
            return panelIdMap[panelId] ?? panelId
        }
        var didUpdate = false
        let remappedRecords = records.map { record in
            guard case .panel(let panelEntry) = record.entry,
                  panelEntry.workspaceId == oldWorkspaceId else {
                return record
            }
            didUpdate = true
            let fallbackSplitPlacement = panelEntry.fallbackSplitPlacement.map {
                ClosedPanelSplitPlacement(
                    orientation: $0.orientation,
                    insertFirst: $0.insertFirst,
                    anchorPanelId: remapAnchor($0.anchorPanelId)
                )
            }
            return ClosedItemHistoryRecord(id: record.id, closedAt: record.closedAt, entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: newWorkspaceId,
                paneId: panelEntry.paneId,
                paneAnchorPanelId: remapAnchor(panelEntry.paneAnchorPanelId),
                restoreInOriginalPane: false,
                tabIndex: panelEntry.tabIndex,
                snapshot: panelEntry.snapshot,
                fallbackSplitPlacement: fallbackSplitPlacement
            )))
        }
        return (remappedRecords, didUpdate)
    }

    private static func recordsByRemappingPanelAnchorIds(
        _ records: [ClosedItemHistoryRecord],
        from oldPanelId: UUID,
        to newPanelId: UUID
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        var didUpdate = false
        let remappedRecords = records.map { record in
            guard case .panel(let panelEntry) = record.entry else { return record }
            let paneAnchorPanelId = panelEntry.paneAnchorPanelId == oldPanelId
                ? newPanelId
                : panelEntry.paneAnchorPanelId
            let fallbackSplitPlacement = panelEntry.fallbackSplitPlacement.map { placement in
                let anchorPanelId = placement.anchorPanelId == oldPanelId
                    ? newPanelId
                    : placement.anchorPanelId
                return ClosedPanelSplitPlacement(
                    orientation: placement.orientation,
                    insertFirst: placement.insertFirst,
                    anchorPanelId: anchorPanelId
                )
            }
            if paneAnchorPanelId != panelEntry.paneAnchorPanelId ||
                fallbackSplitPlacement?.anchorPanelId != panelEntry.fallbackSplitPlacement?.anchorPanelId {
                didUpdate = true
            }
            return ClosedItemHistoryRecord(id: record.id, closedAt: record.closedAt, entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: panelEntry.workspaceId,
                paneId: panelEntry.paneId,
                paneAnchorPanelId: paneAnchorPanelId,
                restoreInOriginalPane: panelEntry.restoreInOriginalPane,
                tabIndex: panelEntry.tabIndex,
                snapshot: panelEntry.snapshot,
                fallbackSplitPlacement: fallbackSplitPlacement
            )))
        }
        return (remappedRecords, didUpdate)
    }

    private static func recordsByRemappingWorkspaceWindowIds(
        _ records: [ClosedItemHistoryRecord],
        from oldWindowId: UUID,
        to newWindowId: UUID
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        var didUpdate = false
        let remappedRecords = records.map { record in
            guard case .workspace(let workspaceEntry) = record.entry,
                  workspaceEntry.windowId == oldWindowId else {
                return record
            }
            didUpdate = true
            return ClosedItemHistoryRecord(id: record.id, closedAt: record.closedAt, entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspaceEntry.workspaceId,
                windowId: newWindowId,
                workspaceIndex: workspaceEntry.workspaceIndex,
                snapshot: workspaceEntry.snapshot
            )))
        }
        return (remappedRecords, didUpdate)
    }

    private static func recordsByRemovingPanelRecords(
        _ records: [ClosedItemHistoryRecord],
        forWorkspaceIds workspaceIds: Set<UUID>
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        let filteredRecords = records.filter { record in
            guard case .panel(let panelEntry) = record.entry else { return true }
            return !workspaceIds.contains(panelEntry.workspaceId)
        }
        return (filteredRecords, filteredRecords.count != records.count)
    }
}
