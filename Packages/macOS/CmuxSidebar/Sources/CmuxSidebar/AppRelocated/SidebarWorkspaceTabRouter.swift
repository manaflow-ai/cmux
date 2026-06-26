import CmuxFoundation
import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// App-target conformer of ``WorkspaceTabRouting`` for one window's sidebar.
///
/// Wires each routing requirement to the matching `TabManager` (per-window
/// order/groups/selection/reorder) and `AppDelegate` (cross-window window/
/// manager resolution and the actual cross-window + bonsplit moves) call so the
/// behavior is byte-identical to the legacy inline drop-delegate code that used
/// to live in `ContentView.swift`. Constructed per window with that window's
/// `TabManager`; the cross-window and bonsplit operations reach the shared
/// `AppDelegate` through `AppDelegate.shared`, exactly as the legacy delegate
/// bodies did.
@MainActor
final class SidebarWorkspaceTabRouter: WorkspaceTabRouting {
    private let tabManager: TabManager

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    // MARK: Local window reads

    var localWorkspaceIds: [UUID] { tabManager.tabs.map(\.id) }

    var selectedWorkspaceId: UUID? { tabManager.selectedTabId }

    var selectedWorkspaceIds: Set<UUID> { tabManager.sidebarSelectedWorkspaceIds }

    func containsLocalWorkspace(_ workspaceId: UUID) -> Bool {
        tabManager.tabs.contains { $0.id == workspaceId }
    }

    func isLocalGroupAnchor(_ workspaceId: UUID) -> Bool {
        tabManager.workspaceGroups.contains { $0.anchorWorkspaceId == workspaceId }
    }

    var hasLocalWorkspaceGroups: Bool { !tabManager.workspaceGroups.isEmpty }

    func topLevelGroupAnchor(forWorkspace workspaceId: UUID) -> UUID? {
        if let groupId = tabManager.tabs.first(where: { $0.id == workspaceId })?.groupId,
           let anchorId = tabManager.workspaceGroups.first(where: { $0.id == groupId })?.anchorWorkspaceId {
            return anchorId
        }
        return workspaceId
    }

    // MARK: Reorder planner inputs

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    ) -> Bool {
        tabManager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
    }

    func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> [UUID] {
        tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> Set<UUID> {
        tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> ClosedRange<Int>? {
        tabManager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    // MARK: Mutations

    @discardableResult
    func reorderSidebarWorkspace(
        workspaceId: UUID,
        toIndex index: Int,
        isDragOperation: Bool,
        usesTopLevelRows: Bool
    ) -> Bool {
        tabManager.reorderSidebarWorkspace(
            tabId: workspaceId,
            toIndex: index,
            isDragOperation: isDragOperation,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    // MARK: Cross-window move

    func isCrossWindowGroupAnchor(_ workspaceId: UUID) -> Bool {
        guard let sourceManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else {
            return false
        }
        return sourceManager.workspaceGroups.contains { $0.anchorWorkspaceId == workspaceId }
    }

    func foreignWorkspaceIsPinned(_ workspaceId: UUID) -> Bool {
        AppDelegate.shared?
            .tabManagerFor(tabId: workspaceId)?
            .tabs.first { $0.id == workspaceId }?.isPinned ?? false
    }

    /// Translate a top-level insertion slot into a raw `tabs` index so the
    /// attach lands the workspace just before that top-level item's run (or at
    /// the end); `attachWorkspace` then normalizes the group runs around it.
    private func crossWindowRawInsertIndex(forTopLevelSlot slot: Int, topLevelIds: [UUID]) -> Int {
        guard slot < topLevelIds.count else { return tabManager.tabs.count }
        let topLevelId = topLevelIds[slot]
        return tabManager.tabs.firstIndex { $0.id == topLevelId } ?? tabManager.tabs.count
    }

    private func crossWindowTopLevelTabIds() -> [UUID] {
        tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowTopLevelPinnedTabIds() -> Set<UUID> {
        tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    @discardableResult
    func performCrossWindowDrop(
        draggedWorkspaceId: UUID,
        targetTopLevelWorkspaceId: UUID?,
        indicator: SidebarDropIndicator?
    ) -> [UUID] {
        guard let app = AppDelegate.shared,
              let destinationWindowId = app.windowId(for: tabManager),
              let sourceManager = app.tabManagerFor(tabId: draggedWorkspaceId),
              // A group header drag carries its anchor; moving only the anchor
              // would dissolve the group, so cross-window header drops are
              // disallowed (also gated in validateDrop).
              !sourceManager.workspaceGroups.contains(where: { $0.anchorWorkspaceId == draggedWorkspaceId }) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.crossWindow.abort reason=unresolvedRouteOrGroupAnchor tab=\(draggedWorkspaceId.uuidString.prefix(5))")
#endif
            return []
        }

        // Move the source window's whole multi-selection when the dragged
        // workspace is part of it; otherwise just the dragged workspace. Group
        // anchors in the selection are excluded for the same reason as above.
        let sourceSelection = sourceManager.sidebarSelectedWorkspaceIds
        let candidateIds: [UUID]
        if sourceSelection.contains(draggedWorkspaceId), sourceSelection.count > 1 {
            candidateIds = sourceManager.tabs.filter { sourceSelection.contains($0.id) }.map(\.id)
        } else {
            candidateIds = [draggedWorkspaceId]
        }
        let sourceAnchorIds = Set(sourceManager.workspaceGroups.map(\.anchorWorkspaceId))
        let movingIds = candidateIds.filter { !sourceAnchorIds.contains($0) }
        guard !movingIds.isEmpty else { return [] }

#if DEBUG
        cmuxDebugLog(
            "sidebar.drop.crossWindow.commit count=\(movingIds.count) " +
            "to=\(destinationWindowId.uuidString.prefix(5))"
        )
#endif
        // A cross-window selection can span pinned and unpinned workspaces, and
        // `attachWorkspace` normalizes each insert into the leading-pinned /
        // unpinned region individually. Plan one base slot *per pin tier* (so a
        // mixed selection doesn't scatter), then insert that tier's workspaces
        // at base + running-offset so they stay a contiguous block in source
        // order — recomputing the slot per workspace against the same indicator
        // would re-anchor to the hovered row and reverse the batch. Pin state
        // can't change mid-drag, so snapshot it once. A skipped move simply
        // doesn't advance the offset (no index gap, no stale selection).
        let pinStateById: [UUID: Bool] = Dictionary(
            uniqueKeysWithValues: movingIds.map { id in
                (id, sourceManager.tabs.first { $0.id == id }?.isPinned ?? false)
            }
        )
        var movedIds: [UUID] = []
        for isPinnedTier in [false, true] {
            let tierIds = movingIds.filter { (pinStateById[$0] ?? false) == isPinnedTier }
            guard !tierIds.isEmpty else { continue }
            // Recompute against the live destination so the tier base reflects
            // workspaces inserted by the previous tier.
            let topLevelIds = crossWindowTopLevelTabIds()
            let slot = SidebarDropPlanner().crossWindowInsertion(
                targetTabId: targetTopLevelWorkspaceId,
                draggedIsPinned: isPinnedTier,
                indicator: indicator,
                tabIds: topLevelIds,
                pinnedTabIds: crossWindowTopLevelPinnedTabIds()
            ).insertionIndex
            let base = crossWindowRawInsertIndex(forTopLevelSlot: slot, topLevelIds: topLevelIds)
            var tierOffset = 0
            for workspaceId in tierIds {
                if app.moveWorkspaceToWindow(
                    workspaceId: workspaceId,
                    windowId: destinationWindowId,
                    atIndex: base + tierOffset,
                    focus: false
                ) {
                    movedIds.append(workspaceId)
                    tierOffset += 1
                }
            }
        }

        guard !movedIds.isEmpty else { return [] }
        // Focus the workspace the user actually grabbed when it moved, else the
        // last successful move. It now lives in this window, so this resolves to
        // the same-manager focus path (no second move).
        let focusId = movedIds.contains(draggedWorkspaceId) ? draggedWorkspaceId : (movedIds.last ?? draggedWorkspaceId)
        _ = app.moveWorkspaceToWindow(workspaceId: focusId, windowId: destinationWindowId, focus: true)
        return movedIds
    }

    // MARK: Bonsplit tab move

    func currentBonsplitDraggedTabId() -> UUID? {
        BonsplitTabDragPayload.currentTransfer()?.tab.id
    }

    func bonsplitSurfaceOwningWorkspaceId(forTabId tabId: UUID) -> UUID? {
        AppDelegate.shared?.locateBonsplitSurface(tabId: tabId)?.workspaceId
    }

    func moveBonsplitTab(tabId: UUID, toWorkspace targetWorkspaceId: UUID) -> Bool {
        AppDelegate.shared?.moveBonsplitTab(
            tabId: tabId,
            toWorkspace: targetWorkspaceId,
            focus: true,
            focusWindow: true
        ) ?? false
    }
}
