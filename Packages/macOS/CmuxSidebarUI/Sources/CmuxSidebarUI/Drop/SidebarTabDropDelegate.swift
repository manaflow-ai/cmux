public import SwiftUI
import CmuxFoundation
public import CmuxSidebar
public import CmuxAppKitSupportUI
#if DEBUG
internal import CMUXDebugLog
#endif

/// The `DropDelegate` for a sidebar workspace row (or the end strip) that
/// reorders a workspace within the window or moves one in from another window.
///
/// All workspace ordering, group/pin, reorder, and cross-window move operations
/// route through the ``WorkspaceTabRouting`` seam, so this delegate carries no
/// reference to the app's `TabManager`/`AppDelegate` god objects and reasons
/// only in value types plus the per-window ``SidebarDragState``. The drag
/// identity is resolved from this window's ``SidebarDragState`` first and falls
/// back to the process-wide cross-window registry the drag state wraps, so an
/// intra-window reorder and a cross-window move share one code path.
@MainActor
public struct SidebarTabDropDelegate: DropDelegate {
    public let targetTabId: UUID?
    public let routing: any WorkspaceTabRouting
    public let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    public let dragState: SidebarDragState
    @Binding public var selectedTabIds: Set<UUID>
    @Binding public var lastSidebarSelectionIndex: Int?
    public let targetRowHeight: CGFloat?
    public let dragAutoScrollController: SidebarDragAutoScrollController

    public init(
        targetTabId: UUID?,
        routing: any WorkspaceTabRouting,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?],
        dragState: SidebarDragState,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>,
        targetRowHeight: CGFloat?,
        dragAutoScrollController: SidebarDragAutoScrollController
    ) {
        self.targetTabId = targetTabId
        self.routing = routing
        self.workspaceGroupIdByWorkspaceId = workspaceGroupIdByWorkspaceId
        self.dragState = dragState
        self._selectedTabIds = selectedTabIds
        self._lastSidebarSelectionIndex = lastSidebarSelectionIndex
        self.targetRowHeight = targetRowHeight
        self.dragAutoScrollController = dragAutoScrollController
    }

    /// The identity of the workspace being dragged, resolved from this window's
    /// `SidebarDragState` first and falling back to the process-wide
    /// cross-window registry for a drag that originated in another window. This
    /// single resolver is the one source of truth the drop path keys on, so an
    /// intra-window reorder and a cross-window move share the same code instead
    /// of forking into parallel drop delegates.
    private var effectiveDraggedTabId: UUID? {
        dragState.draggedTabId ?? dragState.currentWorkspaceDragId
    }

    /// Whether `draggedTabId` belongs to a *different* window than this drop
    /// target — i.e. dropping here moves the workspace into this window rather
    /// than reordering within it.
    private func isCrossWindowDrag(_ draggedTabId: UUID) -> Bool {
        !routing.containsLocalWorkspace(draggedTabId)
    }

    /// Whether the foreign dragged workspace is a group *anchor* in its source
    /// window. A group-header drag carries the anchor id, and moving only the
    /// anchor across windows would dissolve the group and strand its members,
    /// so cross-window drops of a group header are disallowed — the group stays
    /// intact and members can still be dragged out individually.
    private func isCrossWindowGroupAnchorDrag(_ draggedTabId: UUID) -> Bool {
        guard isCrossWindowDrag(draggedTabId) else { return false }
        return routing.isCrossWindowGroupAnchor(draggedTabId)
    }

    /// The destination's top-level sidebar ids (each group is represented by its
    /// anchor; members are folded into the run). A workspace moved in from
    /// another window arrives ungrouped and `attachWorkspace` normalizes it to a
    /// top-level boundary, so the planner and indicator reason in this space —
    /// not raw `tabs` — to match where the workspace actually lands.
    private func crossWindowTopLevelTabIds() -> [UUID] {
        routing.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowTopLevelPinnedTabIds() -> Set<UUID> {
        routing.sidebarReorderPinnedWorkspaceIds(
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
        return routing.topLevelGroupAnchor(forWorkspace: targetTabId)
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
        dragState.foreignDraggedIsPinned = routing.foreignWorkspaceIsPinned(foreignId)
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
            let usesTopLevelRows = routing.sidebarReorderUsesTopLevelRows(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetTabId,
                workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
            )
            return routing.sidebarReorderWorkspaceIds(
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
        let usesTopLevelRows = routing.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
        let reorderTabIds = routing.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedTabIds = routing.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = routing.sidebarReorderLegalInsertionRange(
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
            liveWorkspaceIds: routing.localWorkspaceIds
        )
        let didReorder = routing.reorderSidebarWorkspace(
            workspaceId: draggedTabId,
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
    /// indicated drop position. The whole plan-and-commit (source-selection
    /// expansion, per-pin-tier base-slot planning, the focus move) lives behind
    /// ``WorkspaceTabRouting/performCrossWindowDrop(draggedWorkspaceId:targetTopLevelWorkspaceId:indicator:)``
    /// because every step reaches `AppDelegate`/source-`TabManager` state that
    /// cannot cross the module boundary; this delegate only supplies the drop's
    /// resolved top-level target + indicator and applies the resulting selection.
    private func performCrossWindowDrop(draggedTabId: UUID) -> Bool {
        let movedIds = routing.performCrossWindowDrop(
            draggedWorkspaceId: draggedTabId,
            targetTopLevelWorkspaceId: crossWindowTopLevelTarget(),
            indicator: dragState.dropIndicator
        )
        guard !movedIds.isEmpty else { return false }
        selectedTabIds = Set(movedIds)
        syncSidebarSelection()
        return true
    }

    private func updateDropIndicator(for info: DropInfo) {
        if let draggedTabId = effectiveDraggedTabId, isCrossWindowDrag(draggedTabId) {
            updateCrossWindowDropIndicator(for: info)
            return
        }
        let usesTopLevelRows = routing.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
        let tabIds = routing.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedTabIds = routing.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = routing.sidebarReorderLegalInsertionRange(
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
        let usesTopLevelRows = routing.hasLocalWorkspaceGroups
        guard dragState.dropIndicator != nextIndicator ||
                dragState.dropIndicatorUsesTopLevelRows != usesTopLevelRows else {
            return
        }
        dragState.setDropIndicator(nextIndicator, usesTopLevelRows: usesTopLevelRows)
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? routing.selectedWorkspaceId
        if let selectedId {
            lastSidebarSelectionIndex = routing.localWorkspaceIds.firstIndex(of: selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }

    private func syncSidebarSelection(
        preserving previousSelectionIds: Set<UUID>,
        preferredAnchorWorkspaceId: UUID?
    ) {
        let liveWorkspaceIds = routing.localWorkspaceIds
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy().reconciledSelection(
            previousSelectionIds: previousSelectionIds,
            liveWorkspaceIds: liveWorkspaceIds,
            fallbackSelectedWorkspaceId: routing.selectedWorkspaceId
        )
        selectedTabIds = nextSelectionIds
        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceReorder(
            preferredAnchorWorkspaceId: preferredAnchorWorkspaceId,
            selectedWorkspaceIds: nextSelectionIds,
            focusedWorkspaceId: routing.selectedWorkspaceId,
            liveWorkspaceIds: liveWorkspaceIds
        )
    }

    private func debugIndicator(_ indicator: SidebarDropIndicator?) -> String {
        guard let indicator else { return "nil" }
        let tabText = indicator.tabId.map { String($0.uuidString.prefix(5)) } ?? "end"
        return "\(tabText):\(indicator.edge == .top ? "top" : "bottom")"
    }
}
