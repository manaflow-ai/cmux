public import SwiftUI
public import CmuxAppKitSupportUI
internal import CmuxFoundation
public import CmuxSidebar
#if DEBUG
internal import CMUXDebugLog
#endif

/// `DropDelegate` for a sidebar workspace row (or the end strip) during a
/// workspace reorder drag.
///
/// Handles both an intra-window reorder and a cross-window move through a single
/// resolved drag identity, so the two flows share one drop path rather than
/// forking into parallel delegates. All live state is read/mutated through the
/// injected ``SidebarTabReorderHosting`` seam (so the delegate never imports the
/// app-target `TabManager`/`AppDelegate`); the in-flight drag identity and the
/// drop indicator live on the passed-in ``SidebarDragState``.
@MainActor
public struct SidebarTabDropDelegate: DropDelegate {
    private let targetTabId: UUID?
    private let host: any SidebarTabReorderHosting
    private let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    private let dragState: SidebarDragState
    @Binding private var selectedTabIds: Set<UUID>
    @Binding private var lastSidebarSelectionIndex: Int?
    private let targetRowHeight: CGFloat?
    private let dragAutoScrollController: SidebarDragAutoScrollController

    /// Creates the reorder drop delegate.
    /// - Parameters:
    ///   - targetTabId: The hovered row's workspace id, or `nil` for the end strip.
    ///   - host: The seam exposing destination/source reorder reads and mutations.
    ///   - workspaceGroupIdByWorkspaceId: Snapshot of each workspace's group id,
    ///     used to decide whether the reorder reasons in top-level rows.
    ///   - dragState: This window's in-flight drag/indicator state.
    ///   - selectedTabIds: Binding to the sidebar multi-selection.
    ///   - lastSidebarSelectionIndex: Binding to the sidebar selection anchor index.
    ///   - targetRowHeight: The hovered row's measured height, for edge planning.
    ///   - dragAutoScrollController: Drives edge auto-scroll while hovering.
    public init(
        targetTabId: UUID?,
        host: any SidebarTabReorderHosting,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?],
        dragState: SidebarDragState,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>,
        targetRowHeight: CGFloat?,
        dragAutoScrollController: SidebarDragAutoScrollController
    ) {
        self.targetTabId = targetTabId
        self.host = host
        self.workspaceGroupIdByWorkspaceId = workspaceGroupIdByWorkspaceId
        self.dragState = dragState
        self._selectedTabIds = selectedTabIds
        self._lastSidebarSelectionIndex = lastSidebarSelectionIndex
        self.targetRowHeight = targetRowHeight
        self.dragAutoScrollController = dragAutoScrollController
    }

    /// The identity of the workspace being dragged, resolved from this window's
    /// `SidebarDragState` first and falling back to the process-wide
    /// ``SidebarWorkspaceDragRegistry`` for a drag that originated in another
    /// window. This single resolver is the one source of truth the drop path
    /// keys on, so an intra-window reorder and a cross-window move share the same
    /// code instead of forking into parallel drop delegates.
    private var effectiveDraggedTabId: UUID? {
        dragState.draggedTabId ?? dragState.currentWorkspaceDragId
    }

    /// Whether `draggedTabId` belongs to a *different* window than this drop
    /// target — i.e. dropping here moves the workspace into this window rather
    /// than reordering within it.
    private func isCrossWindowDrag(_ draggedTabId: UUID) -> Bool {
        !host.destinationTabIds.contains(draggedTabId)
    }

    /// Whether the foreign dragged workspace is a group *anchor* in its source
    /// window. A group-header drag carries the anchor id, and moving only the
    /// anchor across windows would dissolve the group and strand its members,
    /// so cross-window drops of a group header are disallowed — the group stays
    /// intact and members can still be dragged out individually. (Migrating a
    /// whole group across windows is out of scope for this feature.)
    private func isCrossWindowGroupAnchorDrag(_ draggedTabId: UUID) -> Bool {
        guard isCrossWindowDrag(draggedTabId) else { return false }
        return host.isGroupAnchorInSourceWindow(draggedTabId)
    }

    /// The destination's top-level sidebar ids (each group is represented by its
    /// anchor; members are folded into the run). A workspace moved in from
    /// another window arrives ungrouped and `attachWorkspace` normalizes it to a
    /// top-level boundary, so the planner and indicator reason in this space —
    /// not raw `tabs` — to match where the workspace actually lands.
    private func crossWindowTopLevelTabIds() -> [UUID] {
        host.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowTopLevelPinnedTabIds() -> Set<UUID> {
        host.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    /// Map the hovered destination row to its top-level representative: a group
    /// member resolves to its group's anchor, since an incoming ungrouped
    /// workspace lands at the group boundary, never inside the run.
    private func crossWindowTopLevelTarget() -> UUID? {
        guard let targetTabId else { return nil }
        if let groupId = host.destinationGroupId(forTab: targetTabId),
           let anchorId = host.destinationGroupAnchor(forGroup: groupId) {
            return anchorId
        }
        return targetTabId
    }

    /// Translate a top-level insertion slot into a raw `tabs` index so the
    /// attach lands the workspace just before that top-level item's run (or at
    /// the end); `attachWorkspace` then normalizes the group runs around it.
    private func crossWindowRawInsertIndex(forTopLevelSlot slot: Int, topLevelIds: [UUID]) -> Int {
        let destinationTabIds = host.destinationTabIds
        guard slot < topLevelIds.count else { return destinationTabIds.count }
        let topLevelId = topLevelIds[slot]
        return destinationTabIds.firstIndex(of: topLevelId) ?? destinationTabIds.count
    }

    /// Mirror a foreign drag's identity into this window's `SidebarDragState`
    /// so the existing drop-indicator, frame-anchor, and failsafe machinery —
    /// all gated on `draggedTabId != nil` — activate unchanged. The id matches
    /// no local row, so no row dims, and the failsafe monitor clears it on
    /// mouse-up (and `performDrop` clears it on a successful drop).
    private func activateForeignDragIfNeeded() {
        guard dragState.draggedTabId == nil,
              let foreignId = dragState.currentWorkspaceDragId,
              isCrossWindowDrag(foreignId),
              !isCrossWindowGroupAnchorDrag(foreignId) else { return }
        // Resolve the foreign workspace's pin state once; it can't change while
        // the drag is in flight, so later hover updates reuse it.
        dragState.foreignDraggedIsPinned = host.foreignTabIsPinned(foreignId)
        dragState.draggedTabId = foreignId
    }

    public func validateDrop(info: DropInfo) -> Bool {
        let hasType = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        guard hasType, let draggedTabId = effectiveDraggedTabId else {
            #if DEBUG
            logDebugEvent(
                "sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
                "hasType=\(hasType) hasDrag=false"
            )
            #endif
            return false
        }
        if isCrossWindowDrag(draggedTabId) {
            // A group header drag carries its anchor id; moving only the anchor
            // would dissolve the source group, so reject cross-window header
            // drops (the group stays intact in its window).
            if isCrossWindowGroupAnchorDrag(draggedTabId) {
                #if DEBUG
                logDebugEvent("sidebar.validateDrop crossWindow=true rejected=groupAnchor")
                #endif
                return false
            }
            // Foreign workspace: any row (or the end strip) in this window is a
            // valid drop target — the workspace will be moved into this window.
            #if DEBUG
            logDebugEvent(
                "sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
                "hasType=true crossWindow=true"
            )
            #endif
            return true
        }
        let targetIsInReorderScope: Bool = {
            guard let targetTabId else { return true }
            let usesTopLevelRows = host.sidebarReorderUsesTopLevelRows(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetTabId,
                workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
            )
            return host.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetTabId,
                usesTopLevelRows: usesTopLevelRows
            ).contains(targetTabId)
        }()
        #if DEBUG
        logDebugEvent(
            "sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "hasType=\(hasType) hasDrag=true inScope=\(targetIsInReorderScope)"
        )
        #endif
        return targetIsInReorderScope
    }

    public func dropEntered(info: DropInfo) {
        #if DEBUG
        logDebugEvent("sidebar.dropEntered target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        activateForeignDragIfNeeded()
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    public func dropExited(info: DropInfo) {
#if DEBUG
        logDebugEvent("sidebar.dropExited target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
#endif
        if dragState.dropIndicator?.tabId == targetTabId {
            dragState.clearDropIndicator()
        }
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        activateForeignDragIfNeeded()
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
#if DEBUG
        logDebugEvent(
            "sidebar.dropUpdated target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "indicator=\(debugIndicator(dragState.dropIndicator))"
        )
#endif
        return DropProposal(operation: .move)
    }

    public func performDrop(info: DropInfo) -> Bool {
        defer {
            dragState.clearDrag()
            dragAutoScrollController.stop()
        }
        #if DEBUG
        logDebugEvent("sidebar.drop target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        guard let draggedTabId = effectiveDraggedTabId else {
#if DEBUG
            logDebugEvent("sidebar.drop.abort reason=missingDraggedTab")
#endif
            return false
        }
        if isCrossWindowDrag(draggedTabId) {
            return performCrossWindowDrop(draggedTabId: draggedTabId)
        }
        let usesTopLevelRows = host.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
        let reorderTabIds = host.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedTabIds = host.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = host.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        guard let fromIndex = reorderTabIds.firstIndex(of: draggedTabId) else {
#if DEBUG
            logDebugEvent("sidebar.drop.abort reason=draggedTabMissing tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }
        guard let targetIndex = SidebarDropPlanner().targetIndex(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
            indicator: dragState.dropIndicator,
            tabIds: reorderTabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalInsertionRange
        ) else {
#if DEBUG
            logDebugEvent(
                "sidebar.drop.abort reason=noTargetIndex tab=\(draggedTabId.uuidString.prefix(5)) " +
                "target=\(targetTabId?.uuidString.prefix(5) ?? "end") indicator=\(debugIndicator(dragState.dropIndicator))"
            )
#endif
            return false
        }

        guard fromIndex != targetIndex else {
#if DEBUG
            logDebugEvent("sidebar.drop.noop from=\(fromIndex) to=\(targetIndex)")
#endif
            return true
        }

#if DEBUG
        logDebugEvent("sidebar.drop.commit tab=\(draggedTabId.uuidString.prefix(5)) from=\(fromIndex) to=\(targetIndex)")
#endif
        let selectionBeforeReorder = selectedTabIds
        let anchorWorkspaceIdBeforeReorder = SidebarWorkspaceSelectionSyncPolicy().anchorWorkspaceId(
            existingAnchorIndex: lastSidebarSelectionIndex,
            liveWorkspaceIds: host.destinationTabIds
        )
        let didReorder = host.reorderSidebarWorkspace(
            tabId: draggedTabId,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: usesTopLevelRows
        )
        syncSidebarSelection(
            preserving: selectionBeforeReorder,
            preferredAnchorWorkspaceId: anchorWorkspaceIdBeforeReorder
        )
        return didReorder
    }

    /// Move a workspace dragged in from another window into this window at the
    /// indicated drop position. Mirrors the existing "Move Workspace to Window"
    /// action but honors the drop index and multi-selection.
    private func performCrossWindowDrop(draggedTabId: UUID) -> Bool {
        guard let destinationWindowId = host.destinationWindowId(),
              host.sourceWindowExists(forTab: draggedTabId),
              // A group header drag carries its anchor; moving only the anchor
              // would dissolve the group, so cross-window header drops are
              // disallowed (also gated in validateDrop).
              !host.isGroupAnchorInSourceWindow(draggedTabId) else {
#if DEBUG
            logDebugEvent("sidebar.drop.crossWindow.abort reason=unresolvedRouteOrGroupAnchor tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }

        // Move the source window's whole multi-selection when the dragged
        // workspace is part of it; otherwise just the dragged workspace. Group
        // anchors in the selection are excluded for the same reason as above.
        let sourceSelection = host.sourceSelectedWorkspaceIds(forTab: draggedTabId)
        let candidateIds: [UUID]
        if sourceSelection.contains(draggedTabId), sourceSelection.count > 1 {
            candidateIds = host.sourceWorkspaceIds(forTab: draggedTabId, matching: sourceSelection)
        } else {
            candidateIds = [draggedTabId]
        }
        let sourceAnchorIds = host.sourceGroupAnchorIds(forTab: draggedTabId)
        let movingIds = candidateIds.filter { !sourceAnchorIds.contains($0) }
        guard !movingIds.isEmpty else { return false }

#if DEBUG
        logDebugEvent(
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
                (id, host.sourceTabIsPinned(forTab: draggedTabId, workspaceId: id))
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
                targetTabId: crossWindowTopLevelTarget(),
                draggedIsPinned: isPinnedTier,
                indicator: dragState.dropIndicator,
                tabIds: topLevelIds,
                pinnedTabIds: crossWindowTopLevelPinnedTabIds()
            ).insertionIndex
            let base = crossWindowRawInsertIndex(forTopLevelSlot: slot, topLevelIds: topLevelIds)
            var tierOffset = 0
            for workspaceId in tierIds {
                if host.moveWorkspaceToWindow(
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

        guard !movedIds.isEmpty else { return false }
        // Focus the workspace the user actually grabbed when it moved, else the
        // last successful move. It now lives in this window, so this resolves to
        // the same-manager focus path (no second move).
        let focusId = movedIds.contains(draggedTabId) ? draggedTabId : (movedIds.last ?? draggedTabId)
        _ = host.moveWorkspaceToWindow(workspaceId: focusId, windowId: destinationWindowId, atIndex: nil, focus: true)
        selectedTabIds = Set(movedIds)
        syncSidebarSelection()
        return true
    }

    private func updateDropIndicator(for info: DropInfo) {
        if let draggedTabId = effectiveDraggedTabId, isCrossWindowDrag(draggedTabId) {
            updateCrossWindowDropIndicator(for: info)
            return
        }
        let usesTopLevelRows = host.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
        let tabIds = host.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedTabIds = host.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = host.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let nextIndicator = SidebarDropPlanner().indicator(
            draggedTabId: dragState.draggedTabId,
            targetTabId: targetTabId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalInsertionRange,
            pointerY: targetTabId == nil ? nil : info.location.y,
            targetHeight: targetRowHeight
        )
        let nextUsesTopLevelRows = nextIndicator != nil && usesTopLevelRows
        guard dragState.dropIndicator != nextIndicator ||
                dragState.dropIndicatorUsesTopLevelRows != nextUsesTopLevelRows else {
            return
        }
        dragState.setDropIndicator(nextIndicator, usesTopLevelRows: usesTopLevelRows)
    }

    /// Drop indicator for a foreign workspace hovering this window. The dragged
    /// workspace is not in this window's list, so the reorder planner (which
    /// removes a source index) does not apply — use the cross-window planner.
    private func updateCrossWindowDropIndicator(for info: DropInfo) {
        // Reuse the pin state stashed when the foreign drag was mirrored in,
        // avoiding a per-pointer-move cross-window lookup.
        let draggedIsPinned = dragState.foreignDraggedIsPinned ?? false
        // Plan in top-level space so the indicator lands on the same group/pin
        // boundary `attachWorkspace` will normalize the dropped workspace to.
        let nextIndicator = SidebarDropPlanner().crossWindowInsertion(
            targetTabId: crossWindowTopLevelTarget(),
            draggedIsPinned: draggedIsPinned,
            indicator: nil,
            tabIds: crossWindowTopLevelTabIds(),
            pinnedTabIds: crossWindowTopLevelPinnedTabIds(),
            pointerY: targetTabId == nil ? nil : info.location.y,
            targetHeight: targetRowHeight
        ).indicator
        let usesTopLevelRows = host.destinationHasWorkspaceGroups
        guard dragState.dropIndicator != nextIndicator ||
                dragState.dropIndicatorUsesTopLevelRows != usesTopLevelRows else {
            return
        }
        dragState.setDropIndicator(nextIndicator, usesTopLevelRows: usesTopLevelRows)
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? host.destinationSelectedTabId
        if let selectedId {
            lastSidebarSelectionIndex = host.destinationTabIds.firstIndex(of: selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }

    private func syncSidebarSelection(
        preserving previousSelectionIds: Set<UUID>,
        preferredAnchorWorkspaceId: UUID?
    ) {
        let liveWorkspaceIds = host.destinationTabIds
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy().reconciledSelection(
            previousSelectionIds: previousSelectionIds,
            liveWorkspaceIds: liveWorkspaceIds,
            fallbackSelectedWorkspaceId: host.destinationSelectedTabId
        )
        selectedTabIds = nextSelectionIds
        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceReorder(
            preferredAnchorWorkspaceId: preferredAnchorWorkspaceId,
            selectedWorkspaceIds: nextSelectionIds,
            focusedWorkspaceId: host.destinationSelectedTabId,
            liveWorkspaceIds: liveWorkspaceIds
        )
    }

    private func debugIndicator(_ indicator: SidebarDropIndicator?) -> String {
        guard let indicator else { return "nil" }
        let tabText = indicator.tabId.map { String($0.uuidString.prefix(5)) } ?? "end"
        return "\(tabText):\(indicator.edge == .top ? "top" : "bottom")"
    }
}
