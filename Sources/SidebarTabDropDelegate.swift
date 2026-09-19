import AppKit
import CmuxAppKitSupportUI
import CmuxCommandPalette
import CmuxCore
import CmuxFeedback
import CmuxFoundation
import CmuxNotifications
import CmuxPanes
import CmuxSettings
import CmuxWorkspaces
import Bonsplit
import Combine
import CmuxSidebarInterpreterClient
import CmuxTerminal
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettingsUI
import CmuxSidebar
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

enum BonsplitTabDragPayload {
    // Keep this declaration nonisolated: SwiftUI's UTType construction and
    // AppKit registration can occur while the app target is still being
    // composed. It is intentionally byte-identical to Bonsplit's public
    // registry type, whose runtime accessors are MainActor-isolated.
    static let typeIdentifier = "com.splittabbar.tabtransfer"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]

    struct Transfer: Equatable {
        struct TabInfo: Equatable {
            let id: UUID
            let kind: String?
        }

        let tab: TabInfo
        let sourcePaneId: UUID

        init(_ transfer: TabDragTransfer) {
            self.tab = TabInfo(
                id: transfer.tab.id.uuid,
                kind: transfer.tab.kind
            )
            self.sourcePaneId = transfer.sourcePaneId.id
        }
    }

    @MainActor
    static func currentTransfer(registry: TabDragTransferRegistry? = nil) -> Transfer? {
        transfer(from: NSPasteboard(name: .drag), registry: registry)
    }

    @MainActor
    static func canRouteWorkspaceDrop(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        registry: TabDragTransferRegistry? = nil,
        pasteboard: NSPasteboard? = nil
    ) -> Bool {
        guard DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes),
              !DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboardTypes) else {
            return false
        }
        return liveTransfer(
            from: pasteboard ?? NSPasteboard(name: .drag),
            registry: registry
        ) != nil
    }

    @MainActor
    static func transfer(
        from pasteboard: NSPasteboard,
        registry: TabDragTransferRegistry? = nil
    ) -> Transfer? {
        guard !DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboard.types) else {
            return nil
        }
        return liveTransfer(from: pasteboard, registry: registry).map(Transfer.init)
    }

    @MainActor
    static func liveTransfer(
        from pasteboard: NSPasteboard,
        registry: TabDragTransferRegistry?
    ) -> TabDragTransfer? {
        if let app = AppDelegate.shared,
           registry == nil || registry === app.tabDragTransferRegistry {
            return app.liveTabDragCapabilityResolver.resolve(from: pasteboard)
        }
        return registry?.resolve(from: pasteboard)
    }
}

@MainActor
struct SidebarTabDropDelegate: DropDelegate {
    let targetTabId: UUID?
    let tabManager: TabManager
    let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    let dragState: SidebarDragState
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController

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
        !tabManager.tabs.contains { $0.id == draggedTabId }
            && !tabManager.workspaceGroups.contains { $0.id == draggedTabId && $0.isEmpty }
    }

    /// Whether the foreign dragged workspace is a group *anchor* in its source
    /// window. A group-header drag carries the anchor id, and moving only the
    /// anchor across windows would dissolve the group and strand its members,
    /// so cross-window drops of a group header are disallowed — the group stays
    /// intact and members can still be dragged out individually. (Migrating a
    /// whole group across windows is out of scope for this feature.)
    private func isCrossWindowGroupAnchorDrag(_ draggedTabId: UUID) -> Bool {
        guard isCrossWindowDrag(draggedTabId) else {
            return false
        }
        if let sourceManager = AppDelegate.shared?.tabManagerFor(tabId: draggedTabId) {
            return sourceManager.workspaceGroups.contains {
                $0.liveAnchorWorkspaceId == draggedTabId
            }
        }
        // An empty group's stable identity is not present in any workspace
        // index, so `tabManagerFor(tabId:)` cannot find its source window.
        // Reject the foreign drag explicitly until whole-group transfer exists.
        return AppDelegate.shared?.mainWindowContexts.values.contains { context in
            context.tabManager !== tabManager
                && context.tabManager.workspaceGroups.contains {
                    $0.id == draggedTabId && $0.isEmpty
                }
        } == true
    }

    /// A sidebar UTI is only a hint. SwiftUI row drops must carry the same
    /// token as the registry's current native workspace session, otherwise a
    /// late payload from an older drag could be applied to a newer one.
    private func acceptsLiveSidebarPayload() -> Bool {
        dragState.acceptsLiveSidebarSessionForCurrentPasteboard()
    }

    /// The destination's top-level sidebar ids (each group is represented by its
    /// anchor; members are folded into the run). A workspace moved in from
    /// another window arrives ungrouped and `attachWorkspace` normalizes it to a
    /// top-level boundary, so the planner and indicator reason in this space —
    /// not raw `tabs` — to match where the workspace actually lands.
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

    /// Map the hovered destination row to its top-level representative: a group
    /// member resolves to its group's anchor, since an incoming ungrouped
    /// workspace lands at the group boundary, never inside the run.
    private func crossWindowTopLevelTarget() -> UUID? {
        guard let targetTabId else { return nil }
        if let groupId = tabManager.tabs.first(where: { $0.id == targetTabId })?.groupId,
           let anchorId = tabManager.workspaceGroups.first(where: { $0.id == groupId })?.anchorWorkspaceId {
            return anchorId
        }
        return targetTabId
    }

    /// Translate a top-level insertion slot into a raw `tabs` index so the
    /// attach lands the workspace just before that top-level item's run (or at
    /// the end); `attachWorkspace` then normalizes the group runs around it.
    private func crossWindowRawInsertIndex(forTopLevelSlot slot: Int, topLevelIds: [UUID]) -> Int {
        guard slot < topLevelIds.count else { return tabManager.tabs.count }
        let topLevelId = topLevelIds[slot]
        if let liveIndex = tabManager.tabs.firstIndex(where: { $0.id == topLevelId }) {
            return liveIndex
        }
        for nextId in topLevelIds.dropFirst(slot + 1) {
            if let nextIndex = tabManager.tabs.firstIndex(where: { $0.id == nextId }) {
                return nextIndex
            }
        }
        return tabManager.tabs.count
    }

    /// Mirror a foreign drag's identity into this window's `SidebarDragState`
    /// so the existing drop-indicator and frame-anchor machinery can activate.
    /// The native source completion clears the mirrored presentation.
    private func activateForeignDragIfNeeded() {
        guard dragState.draggedTabId == nil,
              acceptsLiveSidebarPayload(),
              let foreignId = dragState.currentWorkspaceDragId,
              isCrossWindowDrag(foreignId),
              !isCrossWindowGroupAnchorDrag(foreignId) else { return }
        // Resolve the foreign workspace's pin state once; it can't change while
        // the drag is in flight, so later hover updates reuse it.
        guard dragState.mirrorDragging(tabId: foreignId) else { return }
        dragState.foreignDraggedIsPinned = AppDelegate.shared?
            .tabManagerFor(tabId: foreignId)?
            .tabs.first { $0.id == foreignId }?.isPinned ?? false
    }

    func validateDrop(info: DropInfo) -> Bool {
        let hasType = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        guard hasType, acceptsLiveSidebarPayload(), let draggedTabId = effectiveDraggedTabId else {
            #if DEBUG
            cmuxDebugLog(
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
                cmuxDebugLog("sidebar.validateDrop crossWindow=true rejected=groupAnchor")
                #endif
                return false
            }
            // Foreign workspace: any row (or the end strip) in this window is a
            // valid drop target — the workspace will be moved into this window.
            #if DEBUG
            cmuxDebugLog(
                "sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
                "hasType=true crossWindow=true"
            )
            #endif
            return true
        }
        let targetIsInReorderScope: Bool = {
            guard let targetTabId else { return true }
            let usesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetTabId,
                workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
            )
            if tabManager.workspaceGroups.contains(where: { $0.anchorWorkspaceId == targetTabId }) {
                return tabManager.sidebarReorderWorkspaceIds(
                    forDraggedWorkspaceId: draggedTabId,
                    targetWorkspaceId: targetTabId,
                    usesTopLevelRows: true
                ).contains(targetTabId)
            }
            return tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetTabId,
                usesTopLevelRows: usesTopLevelRows
            ).contains(targetTabId)
        }()
        #if DEBUG
        cmuxDebugLog(
            "sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "hasType=\(hasType) hasDrag=true inScope=\(targetIsInReorderScope)"
        )
        #endif
        return targetIsInReorderScope
    }

    func dropEntered(info: DropInfo) {
        #if DEBUG
        cmuxDebugLog("sidebar.dropEntered target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        activateForeignDragIfNeeded()
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropExited target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
#endif
        // SwiftUI can emit row exits while a valid drag is still over the
        // sidebar, especially after indicator state invalidates row overlays.
        // Hover updates and drag-end own indicator changes.
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        activateForeignDragIfNeeded()
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(pointerX: info.location.x, pointerY: plannerPointerY(for: info))
#if DEBUG
        cmuxDebugLog(
            "sidebar.dropUpdated target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "indicator=\(debugIndicator(dragState.dropIndicator))"
        )
#endif
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        performDrop(
            pointerX: info.location.x,
            pointerY: plannerPointerY(for: info),
            shouldClearDrag: true
        )
    }

    func performDrop(pointerX: CGFloat, pointerY: CGFloat?, shouldClearDrag: Bool = true) -> Bool {
        defer {
            if shouldClearDrag {
                // SwiftUI drop delivery is presentation cleanup only. The
                // retained native source is the single owner of session end.
                dragState.dismissPresentation()
            }
            dragAutoScrollController.stop()
        }
        #if DEBUG
        cmuxDebugLog("sidebar.drop target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        guard acceptsLiveSidebarPayload() else { return false }
        guard let draggedTabId = effectiveDraggedTabId else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=missingDraggedTab")
#endif
            return false
        }
        if isCrossWindowDrag(draggedTabId) {
            return performCrossWindowDrop(draggedTabId: draggedTabId)
        }
        let defaultUsesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
        let explicitGroupId: UUID? = nil
        let usesTopLevelRows = usesTopLevelRowsForDrop(
            draggedTabId: draggedTabId,
            explicitGroupId: explicitGroupId,
            defaultUsesTopLevelRows: defaultUsesTopLevelRows
        )
        let plannerTargetTabId = plannerTargetTabId(usesTopLevelRows: usesTopLevelRows)
        let reorderTabIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedTabIds = tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = tabManager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows,
            explicitGroupId: explicitGroupId
        )
        guard let fromIndex = reorderTabIds.firstIndex(of: draggedTabId) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=draggedTabMissing tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }
        guard let targetIndex = SidebarDropPlanner().targetIndex(
            draggedTabId: draggedTabId,
            targetTabId: plannerTargetTabId,
            indicator: dragState.dropIndicator,
            tabIds: reorderTabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalInsertionRange
        ) else {
#if DEBUG
            cmuxDebugLog(
                "sidebar.drop.abort reason=noTargetIndex tab=\(draggedTabId.uuidString.prefix(5)) " +
                "target=\(targetTabId?.uuidString.prefix(5) ?? "end") indicator=\(debugIndicator(dragState.dropIndicator))"
            )
#endif
            return false
        }

        let movingIds = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
            orderedWorkspaceIds: tabManager.tabs.map(\.id),
            selectedIds: selectedTabIds,
            draggedId: draggedTabId,
            anchorIds: Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
        )
        if movingIds.count > 1 {
#if DEBUG
            cmuxDebugLog("sidebar.drop.commit tabs=\(movingIds.count) dragged=\(draggedTabId.uuidString.prefix(5)) to=\(targetIndex)")
#endif
            let blockSelectionBeforeReorder = selectedTabIds
            let blockAnchorWorkspaceIdBeforeReorder = SidebarWorkspaceSelectionSyncPolicy().anchorWorkspaceId(
                existingAnchorIndex: lastSidebarSelectionIndex,
                liveWorkspaceIds: tabManager.tabs.map(\.id)
            )
            let didReorder = tabManager.reorderSidebarWorkspaces(
                tabIds: movingIds,
                draggedTabId: draggedTabId,
                toIndex: targetIndex,
                isDragOperation: true,
                usesTopLevelRows: usesTopLevelRows,
                explicitGroupId: explicitGroupId
            )
            syncSidebarSelection(
                preserving: blockSelectionBeforeReorder,
                preferredAnchorWorkspaceId: blockAnchorWorkspaceIdBeforeReorder
            )
            return didReorder
        }

        guard fromIndex != targetIndex || explicitGroupId != nil else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.noop from=\(fromIndex) to=\(targetIndex)")
#endif
            return true
        }

#if DEBUG
        cmuxDebugLog("sidebar.drop.commit tab=\(draggedTabId.uuidString.prefix(5)) from=\(fromIndex) to=\(targetIndex)")
#endif
        let selectionBeforeReorder = selectedTabIds
        let anchorWorkspaceIdBeforeReorder = SidebarWorkspaceSelectionSyncPolicy().anchorWorkspaceId(
            existingAnchorIndex: lastSidebarSelectionIndex,
            liveWorkspaceIds: tabManager.tabs.map(\.id)
        )
        let didReorder = tabManager.reorderSidebarWorkspace(
            tabId: draggedTabId,
            toIndex: targetIndex,
            isDragOperation: true,
            usesTopLevelRows: usesTopLevelRows,
            explicitGroupId: explicitGroupId
        )
        syncSidebarSelection(
            preserving: selectionBeforeReorder,
            preferredAnchorWorkspaceId: anchorWorkspaceIdBeforeReorder
        )
        return didReorder
    }

    private func usesTopLevelRowsForDrop(
        draggedTabId: UUID?,
        explicitGroupId: UUID?,
        defaultUsesTopLevelRows: Bool
    ) -> Bool {
        guard explicitGroupId == nil else { return false }
        guard !defaultUsesTopLevelRows else { return true }
        guard let draggedTabId,
              tabManager.tabs.contains(where: { $0.id == draggedTabId }),
              let targetTabId,
              let targetGroupId = workspaceGroupIdByWorkspaceId[targetTabId] ?? nil,
              let group = tabManager.workspaceGroups.first(where: { $0.id == targetGroupId }),
              group.anchorWorkspaceId != targetTabId else {
            return false
        }
        return true
    }

    private func plannerTargetTabId(usesTopLevelRows: Bool) -> UUID? {
        guard usesTopLevelRows,
              let targetTabId,
              let targetGroupId = workspaceGroupIdByWorkspaceId[targetTabId] ?? nil,
              let group = tabManager.workspaceGroups.first(where: { $0.id == targetGroupId }),
              group.anchorWorkspaceId != targetTabId else {
            return targetTabId
        }
        return group.anchorWorkspaceId
    }

    private func plannerPointerY(for info: DropInfo) -> CGFloat? {
        return plannerPointerY(pointerY: info.location.y)
    }

    private func plannerPointerY(pointerY: CGFloat?) -> CGFloat? {
        guard targetTabId != nil else { return nil }
        return pointerY
    }

    /// Move a workspace dragged in from another window into this window at the
    /// indicated drop position. Mirrors the existing "Move Workspace to Window"
    /// action but honors the drop index and multi-selection.
    private func performCrossWindowDrop(draggedTabId: UUID) -> Bool {
        guard let app = AppDelegate.shared,
              let destinationWindowId = app.windowId(for: tabManager),
              let sourceManager = app.tabManagerFor(tabId: draggedTabId),
              // A group header drag carries its anchor; moving only the anchor
              // would dissolve the group, so cross-window header drops are
              // disallowed (also gated in validateDrop).
              !sourceManager.workspaceGroups.contains(where: { $0.liveAnchorWorkspaceId == draggedTabId }) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.crossWindow.abort reason=unresolvedRouteOrGroupAnchor tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }

        let movingIds = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
            orderedWorkspaceIds: sourceManager.tabs.map(\.id),
            selectedIds: sourceManager.sidebarSelectedWorkspaceIds,
            draggedId: draggedTabId,
            anchorIds: Set(sourceManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
        )
        guard !movingIds.isEmpty else { return false }

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
                targetTabId: crossWindowTopLevelTarget(),
                draggedIsPinned: isPinnedTier,
                indicator: dragState.dropIndicator,
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

        guard !movedIds.isEmpty else { return false }
        // Focus the workspace the user actually grabbed when it moved, else the
        // last successful move. It now lives in this window, so this resolves to
        // the same-manager focus path (no second move).
        let focusId = movedIds.contains(draggedTabId) ? draggedTabId : (movedIds.last ?? draggedTabId)
        _ = app.moveWorkspaceToWindow(workspaceId: focusId, windowId: destinationWindowId, focus: true)
        selectedTabIds = Set(movedIds)
        syncSidebarSelection()
        return true
    }

    private func updateDropIndicator(for info: DropInfo) {
        updateDropIndicator(pointerX: info.location.x, pointerY: plannerPointerY(for: info))
    }

    func updateDropIndicator(pointerX: CGFloat, pointerY: CGFloat?) {
        if let draggedTabId = effectiveDraggedTabId, isCrossWindowDrag(draggedTabId) {
            updateCrossWindowDropIndicator(pointerY: pointerY)
            return
        }
        let defaultUsesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
        let explicitGroupId: UUID? = nil
        let usesTopLevelRows = usesTopLevelRowsForDrop(
            draggedTabId: dragState.draggedTabId,
            explicitGroupId: explicitGroupId,
            defaultUsesTopLevelRows: defaultUsesTopLevelRows
        )
        let plannerTargetTabId = plannerTargetTabId(usesTopLevelRows: usesTopLevelRows)
        let tabIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedTabIds = tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = tabManager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: plannerTargetTabId,
            usesTopLevelRows: usesTopLevelRows,
            explicitGroupId: explicitGroupId
        )
        // A noncontiguous selection block coalesces at ANY gap, including the
        // dragged row's own edges, so those gaps are real drop targets.
        let blockCoalesces: Bool
        if let draggedTabId = dragState.draggedTabId {
            let blockResolver = SidebarWorkspaceDragBlockResolver()
            blockCoalesces = blockResolver.blockOccupiesNoncontiguousRows(
                blockIds: Set(blockResolver.movingWorkspaceIds(
                    orderedWorkspaceIds: tabManager.tabs.map(\.id),
                    selectedIds: selectedTabIds,
                    draggedId: draggedTabId,
                    anchorIds: Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
                )),
                rowSpaceIds: tabIds
            )
        } else {
            blockCoalesces = false
        }
        let plannedIndicator = SidebarDropPlanner().indicator(
            draggedTabId: dragState.draggedTabId,
            targetTabId: plannerTargetTabId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalInsertionRange,
            pointerY: pointerY,
            targetHeight: targetRowHeight,
            suppressesNoOp: !blockCoalesces
        )
        let nextIndicator = plannedIndicator
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
    private func updateCrossWindowDropIndicator(pointerY: CGFloat?) {
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
            pointerY: targetTabId == nil ? nil : pointerY,
            targetHeight: targetRowHeight
        ).indicator
        let usesTopLevelRows = !tabManager.workspaceGroups.isEmpty
        guard dragState.dropIndicator != nextIndicator ||
                dragState.dropIndicatorUsesTopLevelRows != usesTopLevelRows else {
            return
        }
        dragState.setDropIndicator(nextIndicator, usesTopLevelRows: usesTopLevelRows)
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? tabManager.selectedTabId
        if let selectedId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        } else {
            lastSidebarSelectionIndex = nil
        }
    }

    private func syncSidebarSelection(
        preserving previousSelectionIds: Set<UUID>,
        preferredAnchorWorkspaceId: UUID?
    ) {
        let liveWorkspaceIds = tabManager.tabs.map(\.id)
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy().reconciledSelection(
            previousSelectionIds: previousSelectionIds,
            liveWorkspaceIds: liveWorkspaceIds,
            fallbackSelectedWorkspaceId: tabManager.selectedTabId
        )
        selectedTabIds = nextSelectionIds
        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceReorder(
            preferredAnchorWorkspaceId: preferredAnchorWorkspaceId,
            selectedWorkspaceIds: nextSelectionIds,
            focusedWorkspaceId: tabManager.selectedTabId,
            liveWorkspaceIds: liveWorkspaceIds
        )
    }

    private func debugIndicator(_ indicator: SidebarDropIndicator?) -> String {
        guard let indicator else { return "nil" }
        let tabText = indicator.tabId.map { String($0.uuidString.prefix(5)) } ?? "end"
        return "\(tabText):\(indicator.edge == .top ? "top" : "bottom")"
    }
}

struct ExtensionSidebarBrowserStackDropDelegate: DropDelegate {
    let targetWorkspaceId: UUID
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding var draggedTabId: UUID?
    let targetRowHeight: CGFloat?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
            && draggedTabId != nil
            && orderedRows.count > 1
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == targetWorkspaceId {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId else {
            return false
        }
        let resolvedDropIndicator = plannedDropIndicator(for: info)
        guard let insertionPosition = insertionPosition(
            draggedWorkspaceId: draggedTabId,
            indicator: resolvedDropIndicator
        ) else {
            return false
        }
        guard let move = move(
            draggedWorkspaceId: draggedTabId,
            insertionPosition: insertionPosition,
            indicator: resolvedDropIndicator
        ) else {
            return false
        }
        return onMove(move)
    }

    private func updateDropIndicator(for info: DropInfo) {
        let nextIndicator = plannedDropIndicator(for: info)
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func plannedDropIndicator(for info: DropInfo) -> SidebarDropIndicator? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        return SidebarDropPlanner().indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetWorkspaceId,
            tabIds: workspaceIds,
            pinnedTabIds: [],
            pointerY: info.location.y,
            targetHeight: targetRowHeight
        ) ?? ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).sectionBoundaryIndicator(
            draggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetWorkspaceId,
            pointerY: info.location.y,
            targetHeight: targetRowHeight
        )
    }

    private func insertionPosition(draggedWorkspaceId: UUID, indicator: SidebarDropIndicator?) -> Int? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        if let indicator {
            if let indicatorWorkspaceId = indicator.tabId {
                guard let indicatorIndex = workspaceIds.firstIndex(of: indicatorWorkspaceId) else { return nil }
                return indicator.edge == .bottom ? indicatorIndex + 1 : indicatorIndex
            }
            return workspaceIds.count
        }

        guard let sourceIndex = workspaceIds.firstIndex(of: draggedWorkspaceId),
              let targetIndex = workspaceIds.firstIndex(of: targetWorkspaceId) else {
            return nil
        }
        return sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
    }

    private func move(
        draggedWorkspaceId: UUID,
        insertionPosition: Int,
        indicator: SidebarDropIndicator?
    ) -> CmuxSidebarProviderWorkspaceMove? {
        ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
            draggedWorkspaceId: draggedWorkspaceId,
            insertionPosition: insertionPosition,
            preferredTargetSectionId: preferredTargetSectionId(indicator: indicator)
        )
    }

    private func preferredTargetSectionId(indicator: SidebarDropIndicator?) -> String? {
        ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).preferredSectionId(
            targetWorkspaceId: targetWorkspaceId,
            indicator: indicator
        )
    }
}

enum SidebarSelection {
    case tabs
    case notifications
}
