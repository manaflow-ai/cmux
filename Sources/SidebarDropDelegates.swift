import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
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

enum SidebarAutoScrollDirection: Equatable {
    case up
    case down
}

struct SidebarAutoScrollPlan: Equatable {
    let direction: SidebarAutoScrollDirection
    let pointsPerTick: CGFloat
}

enum SidebarDragAutoScrollPlanner {
    static let edgeInset: CGFloat = 44
    static let minStep: CGFloat = 2
    static let maxStep: CGFloat = 12

    static func plan(
        distanceToTop: CGFloat,
        distanceToBottom: CGFloat,
        edgeInset: CGFloat = SidebarDragAutoScrollPlanner.edgeInset,
        minStep: CGFloat = SidebarDragAutoScrollPlanner.minStep,
        maxStep: CGFloat = SidebarDragAutoScrollPlanner.maxStep
    ) -> SidebarAutoScrollPlan? {
        guard edgeInset > 0, maxStep >= minStep else { return nil }
        if distanceToTop <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToTop) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .up, pointsPerTick: step)
        }
        if distanceToBottom <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToBottom) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .down, pointsPerTick: step)
        }
        return nil
    }
}

@MainActor
final class SidebarDragAutoScrollController: ObservableObject {
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var activePlan: SidebarAutoScrollPlan?

    func attach(scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    func updateFromDragLocation() {
        guard let scrollView else {
            stop()
            return
        }
        guard let plan = plan(for: scrollView) else {
            stop()
            return
        }
        activePlan = plan
        startTimerIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activePlan = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons != 0 else {
            stop()
            return
        }
        guard let scrollView else {
            stop()
            return
        }

        // AppKit drag/drop autoscroll guidance recommends autoscroll(with:)
        // when periodic drag updates are available; use it first.
        if applyNativeAutoscroll(to: scrollView) {
            activePlan = plan(for: scrollView)
            if activePlan == nil {
                stop()
            }
            return
        }

        activePlan = self.plan(for: scrollView)
        guard let plan = activePlan else {
            stop()
            return
        }
        _ = apply(plan: plan, to: scrollView)
    }

    private func applyNativeAutoscroll(to scrollView: NSScrollView) -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break
        default:
            return false
        }

        let clipView = scrollView.contentView
        let didScroll = clipView.autoscroll(with: event)
        if didScroll {
            scrollView.reflectScrolledClipView(clipView)
        }
        return didScroll
    }

    private func distancesToEdges(mousePoint: CGPoint, viewportHeight: CGFloat, isFlipped: Bool) -> (top: CGFloat, bottom: CGFloat) {
        if isFlipped {
            return (top: mousePoint.y, bottom: viewportHeight - mousePoint.y)
        }
        return (top: viewportHeight - mousePoint.y, bottom: mousePoint.y)
    }

    private func planForMousePoint(_ mousePoint: CGPoint, in clipView: NSClipView) -> SidebarAutoScrollPlan? {
        let viewportHeight = clipView.bounds.height
        guard viewportHeight > 0 else { return nil }

        let distances = distancesToEdges(mousePoint: mousePoint, viewportHeight: viewportHeight, isFlipped: clipView.isFlipped)
        return SidebarDragAutoScrollPlanner.plan(distanceToTop: distances.top, distanceToBottom: distances.bottom)
    }

    private func mousePoint(in clipView: NSClipView) -> CGPoint {
        let mouseInWindow = clipView.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        return clipView.convert(mouseInWindow, from: nil)
    }

    private func currentPlan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        let clipView = scrollView.contentView
        let mouse = mousePoint(in: clipView)
        return planForMousePoint(mouse, in: clipView)
    }

    private func plan(for scrollView: NSScrollView) -> SidebarAutoScrollPlan? {
        currentPlan(for: scrollView)
    }

    private func apply(plan: SidebarAutoScrollPlan, to scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        let clipView = scrollView.contentView
        let maxOriginY = max(0, documentView.bounds.height - clipView.bounds.height)
        guard maxOriginY > 0 else { return false }

        let directionMultiplier: CGFloat = (plan.direction == .down) ? 1 : -1
        let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
        let delta = directionMultiplier * flippedMultiplier * plan.pointsPerTick
        let currentY = clipView.bounds.origin.y
        let targetY = min(max(currentY + delta, 0), maxOriginY)
        guard abs(targetY - currentY) > 0.01 else { return false }

        clipView.scroll(to: CGPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

/// Immutable, equatable snapshot of the group list a row's "Move to Group"
/// submenu can offer. Computed once per parent body eval and passed into
/// each TabItemView so the row's `==` covers group changes (renames, adds,
/// deletes) — the row's snapshot-boundary rule forbids reading
/// `tabManager.workspaceGroups` from inside the contextMenu builder.
enum SidebarTabDragPayload {
    static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    static let prefix = "cmux.sidebar-tab."

    static func provider(for tabId: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = "\(prefix)\(tabId.uuidString)"
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            let data = payload.data(using: .utf8)
            Task { @MainActor in
                completion(data, nil)
            }
            return nil
        }
        return provider
    }

}

enum BonsplitTabDragPayload {
    static let typeIdentifier = "com.splittabbar.tabtransfer"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    private static let currentProcessId = Int32(ProcessInfo.processInfo.processIdentifier)

    struct Transfer: Decodable {
        struct TabInfo: Decodable {
            let id: UUID
            let kind: String?
        }

        let tab: TabInfo
        let sourcePaneId: UUID
        let sourceProcessId: Int32

        private enum CodingKeys: String, CodingKey {
            case tab
            case sourcePaneId
            case sourceProcessId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.tab = try container.decode(TabInfo.self, forKey: .tab)
            self.sourcePaneId = try container.decode(UUID.self, forKey: .sourcePaneId)
            // Legacy payloads won't include this field. Treat as foreign process.
            self.sourceProcessId = try container.decodeIfPresent(Int32.self, forKey: .sourceProcessId) ?? -1
        }
    }

    private static func isCurrentProcessTransfer(_ transfer: Transfer) -> Bool {
        transfer.sourceProcessId == currentProcessId
    }

    static func currentTransfer() -> Transfer? {
        transfer(from: NSPasteboard(name: .drag))
    }

    static func canRouteWorkspaceDrop(pasteboardTypes: [NSPasteboard.PasteboardType]?) -> Bool {
        DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
            && !DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboardTypes)
    }

    static func transfer(from pasteboard: NSPasteboard) -> Transfer? {
        guard !DragOverlayRoutingPolicy.hasFilePreviewTransfer(pasteboard.types) else {
            return nil
        }
        let type = NSPasteboard.PasteboardType(typeIdentifier)

        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        if let raw = pasteboard.string(forType: type),
           let data = raw.data(using: .utf8),
           let transfer = try? JSONDecoder().decode(Transfer.self, from: data),
           isCurrentProcessTransfer(transfer) {
            return transfer
        }

        return nil
    }
}

struct SidebarBonsplitTabDropDelegate: DropDelegate {
    let targetWorkspaceId: UUID
    let tabManager: TabManager
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [BonsplitTabDragPayload.typeIdentifier]) else { return false }
        return BonsplitTabDragPayload.currentTransfer() != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let transfer = BonsplitTabDragPayload.currentTransfer(),
              let app = AppDelegate.shared else {
            return false
        }

        if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
           source.workspaceId == targetWorkspaceId {
            syncSidebarSelection()
            return true
        }

        guard app.moveBonsplitTab(
            tabId: transfer.tab.id,
            toWorkspace: targetWorkspaceId,
            focus: true,
            focusWindow: true
        ) else {
            return false
        }

        selectedTabIds = [targetWorkspaceId]
        syncSidebarSelection()
        return true
    }

    private func syncSidebarSelection() {
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}

@MainActor
enum SidebarWorkspaceSelectionSyncPolicy {
    static func reconciledSelection(
        previousSelectionIds: Set<UUID>,
        liveWorkspaceIds: [UUID],
        fallbackSelectedWorkspaceId: UUID?
    ) -> Set<UUID> {
        let liveIdSet = Set(liveWorkspaceIds)
        let liveSelectionIds = previousSelectionIds.filter { liveIdSet.contains($0) }
        if !liveSelectionIds.isEmpty {
            return liveSelectionIds
        }
        if let fallbackSelectedWorkspaceId, liveIdSet.contains(fallbackSelectedWorkspaceId) {
            return [fallbackSelectedWorkspaceId]
        }
        return []
    }

    static func anchorIndex(
        preferredWorkspaceId: UUID?,
        selectedWorkspaceIds: Set<UUID>,
        liveWorkspaceIds: [UUID]
    ) -> Int? {
        if let preferredWorkspaceId,
           selectedWorkspaceIds.contains(preferredWorkspaceId),
           let preferredIndex = liveWorkspaceIds.firstIndex(of: preferredWorkspaceId) {
            return preferredIndex
        }
        return liveWorkspaceIds.firstIndex { selectedWorkspaceIds.contains($0) }
    }

    static func anchorWorkspaceId(
        existingAnchorIndex: Int?,
        liveWorkspaceIds: [UUID]
    ) -> UUID? {
        guard let existingAnchorIndex,
              liveWorkspaceIds.indices.contains(existingAnchorIndex) else {
            return nil
        }
        return liveWorkspaceIds[existingAnchorIndex]
    }

    static func shiftClickAnchorIndex(
        existingAnchorIndex: Int?,
        selectedWorkspaceIds: Set<UUID>,
        focusedWorkspaceId: UUID?,
        liveWorkspaceIds: [UUID]
    ) -> Int? {
        if let existingAnchorIndex,
           liveWorkspaceIds.indices.contains(existingAnchorIndex) {
            return existingAnchorIndex
        }
        if selectedWorkspaceIds.count == 1,
           let selectedWorkspaceId = selectedWorkspaceIds.first,
           let selectedIndex = liveWorkspaceIds.firstIndex(of: selectedWorkspaceId) {
            return selectedIndex
        }
        if let focusedWorkspaceId {
            return liveWorkspaceIds.firstIndex(of: focusedWorkspaceId)
        }
        return nil
    }

    static func anchorIndexAfterWorkspaceClick(
        isShiftClick: Bool,
        resolvedShiftAnchorIndex: Int?,
        clickedIndex: Int
    ) -> Int {
        isShiftClick ? (resolvedShiftAnchorIndex ?? clickedIndex) : clickedIndex
    }

    static func anchorIndexAfterWorkspaceReorder(
        preferredAnchorWorkspaceId: UUID?,
        selectedWorkspaceIds: Set<UUID>,
        focusedWorkspaceId: UUID?,
        liveWorkspaceIds: [UUID]
    ) -> Int? {
        if let preferredAnchorWorkspaceId,
           selectedWorkspaceIds.contains(preferredAnchorWorkspaceId),
           let anchorIndex = liveWorkspaceIds.firstIndex(of: preferredAnchorWorkspaceId) {
            return anchorIndex
        }
        return anchorIndex(
            preferredWorkspaceId: focusedWorkspaceId,
            selectedWorkspaceIds: selectedWorkspaceIds,
            liveWorkspaceIds: liveWorkspaceIds
        )
    }
}

@MainActor
struct SidebarTabDropDelegate: DropDelegate {
    let targetTabId: UUID?
    let tabManager: TabManager
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
        dragState.draggedTabId ?? SidebarWorkspaceDragRegistry.currentWorkspaceId
    }

    /// Whether `draggedTabId` belongs to a *different* window than this drop
    /// target — i.e. dropping here moves the workspace into this window rather
    /// than reordering within it.
    private func isCrossWindowDrag(_ draggedTabId: UUID) -> Bool {
        !tabManager.tabs.contains { $0.id == draggedTabId }
    }

    /// Whether the foreign dragged workspace is a group *anchor* in its source
    /// window. A group-header drag carries the anchor id, and moving only the
    /// anchor across windows would dissolve the group and strand its members,
    /// so cross-window drops of a group header are disallowed — the group stays
    /// intact and members can still be dragged out individually. (Migrating a
    /// whole group across windows is out of scope for this feature.)
    private func isCrossWindowGroupAnchorDrag(_ draggedTabId: UUID) -> Bool {
        guard isCrossWindowDrag(draggedTabId),
              let sourceManager = AppDelegate.shared?.tabManagerFor(tabId: draggedTabId) else {
            return false
        }
        return sourceManager.workspaceGroups.contains { $0.anchorWorkspaceId == draggedTabId }
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
        return tabManager.tabs.firstIndex { $0.id == topLevelId } ?? tabManager.tabs.count
    }

    /// Mirror a foreign drag's identity into this window's `SidebarDragState`
    /// so the existing drop-indicator, frame-anchor, and failsafe machinery —
    /// all gated on `draggedTabId != nil` — activate unchanged. The id matches
    /// no local row, so no row dims, and the failsafe monitor clears it on
    /// mouse-up (and `performDrop` clears it on a successful drop).
    private func activateForeignDragIfNeeded() {
        guard dragState.draggedTabId == nil,
              let foreignId = SidebarWorkspaceDragRegistry.currentWorkspaceId,
              isCrossWindowDrag(foreignId),
              !isCrossWindowGroupAnchorDrag(foreignId) else { return }
        // Resolve the foreign workspace's pin state once; it can't change while
        // the drag is in flight, so later hover updates reuse it.
        dragState.foreignDraggedIsPinned = AppDelegate.shared?
            .tabManagerFor(tabId: foreignId)?
            .tabs.first { $0.id == foreignId }?.isPinned ?? false
        dragState.draggedTabId = foreignId
    }

    func validateDrop(info: DropInfo) -> Bool {
        let hasType = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        guard hasType, let draggedTabId = effectiveDraggedTabId else {
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
            return tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedTabId,
                targetWorkspaceId: targetTabId
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
        if dragState.dropIndicator?.tabId == targetTabId {
            dragState.clearDropIndicator()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        activateForeignDragIfNeeded()
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
#if DEBUG
        cmuxDebugLog(
            "sidebar.dropUpdated target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "indicator=\(debugIndicator(dragState.dropIndicator))"
        )
#endif
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragState.clearDrag()
            dragAutoScrollController.stop()
        }
        #if DEBUG
        cmuxDebugLog("sidebar.drop target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        guard let draggedTabId = effectiveDraggedTabId else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=missingDraggedTab")
#endif
            return false
        }
        if isCrossWindowDrag(draggedTabId) {
            return performCrossWindowDrop(draggedTabId: draggedTabId)
        }
        let usesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId
        )
        let reorderTabIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId
        )
        let pinnedTabIds = tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId
        )
        let legalInsertionRange = tabManager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        guard let fromIndex = reorderTabIds.firstIndex(of: draggedTabId) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=draggedTabMissing tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }
        guard let targetIndex = SidebarDropPlanner.targetIndex(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
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

        guard fromIndex != targetIndex else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.noop from=\(fromIndex) to=\(targetIndex)")
#endif
            return true
        }

#if DEBUG
        cmuxDebugLog("sidebar.drop.commit tab=\(draggedTabId.uuidString.prefix(5)) from=\(fromIndex) to=\(targetIndex)")
#endif
        let selectionBeforeReorder = selectedTabIds
        let anchorWorkspaceIdBeforeReorder = SidebarWorkspaceSelectionSyncPolicy.anchorWorkspaceId(
            existingAnchorIndex: lastSidebarSelectionIndex,
            liveWorkspaceIds: tabManager.tabs.map(\.id)
        )
        let didReorder = tabManager.reorderSidebarWorkspace(
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
        guard let app = AppDelegate.shared,
              let destinationWindowId = app.windowId(for: tabManager),
              let sourceManager = app.tabManagerFor(tabId: draggedTabId),
              // A group header drag carries its anchor; moving only the anchor
              // would dissolve the group, so cross-window header drops are
              // disallowed (also gated in validateDrop).
              !sourceManager.workspaceGroups.contains(where: { $0.anchorWorkspaceId == draggedTabId }) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.crossWindow.abort reason=unresolvedRouteOrGroupAnchor tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }

        // Move the source window's whole multi-selection when the dragged
        // workspace is part of it; otherwise just the dragged workspace. Group
        // anchors in the selection are excluded for the same reason as above.
        let sourceSelection = sourceManager.sidebarSelectedWorkspaceIds
        let candidateIds: [UUID]
        if sourceSelection.contains(draggedTabId), sourceSelection.count > 1 {
            candidateIds = sourceManager.tabs.filter { sourceSelection.contains($0.id) }.map(\.id)
        } else {
            candidateIds = [draggedTabId]
        }
        let sourceAnchorIds = Set(sourceManager.workspaceGroups.map(\.anchorWorkspaceId))
        let movingIds = candidateIds.filter { !sourceAnchorIds.contains($0) }
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
            let slot = SidebarDropPlanner.crossWindowInsertion(
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
        if let draggedTabId = effectiveDraggedTabId, isCrossWindowDrag(draggedTabId) {
            updateCrossWindowDropIndicator(for: info)
            return
        }
        let usesTopLevelRows = tabManager.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId
        )
        let tabIds = tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let pinnedTabIds = tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let legalInsertionRange = tabManager.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: dragState.draggedTabId,
            targetWorkspaceId: targetTabId,
            usesTopLevelRows: usesTopLevelRows
        )
        let nextIndicator = SidebarDropPlanner.indicator(
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
        let nextIndicator = SidebarDropPlanner.crossWindowInsertion(
            targetTabId: crossWindowTopLevelTarget(),
            draggedIsPinned: draggedIsPinned,
            indicator: nil,
            tabIds: crossWindowTopLevelTabIds(),
            pinnedTabIds: crossWindowTopLevelPinnedTabIds(),
            pointerY: targetTabId == nil ? nil : info.location.y,
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
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy.reconciledSelection(
            previousSelectionIds: previousSelectionIds,
            liveWorkspaceIds: liveWorkspaceIds,
            fallbackSelectedWorkspaceId: tabManager.selectedTabId
        )
        selectedTabIds = nextSelectionIds
        lastSidebarSelectionIndex = SidebarWorkspaceSelectionSyncPolicy.anchorIndexAfterWorkspaceReorder(
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

struct ExtensionSidebarBrowserStackDropRow: Equatable {
    let workspaceId: UUID
    let sectionId: String
}

enum ExtensionSidebarBrowserStackDropPlanner {
    static func move(
        draggedWorkspaceId: UUID,
        insertionPosition: Int,
        orderedRows: [ExtensionSidebarBrowserStackDropRow],
        preferredTargetSectionId: String? = nil
    ) -> CmuxSidebarProviderWorkspaceMove? {
        guard let sourceIndex = orderedRows.firstIndex(where: { $0.workspaceId == draggedWorkspaceId }) else {
            return nil
        }
        let sourceRow = orderedRows[sourceIndex]
        let remainingRows = orderedRows.filter { $0.workspaceId != draggedWorkspaceId }
        guard !remainingRows.isEmpty else { return nil }
        let adjustedInsertionPosition = insertionPosition > sourceIndex
            ? insertionPosition - 1
            : insertionPosition
        let clampedInsertionPosition = min(max(adjustedInsertionPosition, 0), remainingRows.count)

        let targetSectionId: String
        let targetIndex: Int
        if let preferredTargetSectionId {
            targetSectionId = preferredTargetSectionId
            targetIndex = remainingRows[..<clampedInsertionPosition].filter { $0.sectionId == targetSectionId }.count
        } else if clampedInsertionPosition < remainingRows.count {
            let targetRow = remainingRows[clampedInsertionPosition]
            targetSectionId = targetRow.sectionId
            targetIndex = remainingRows[..<clampedInsertionPosition].filter { $0.sectionId == targetSectionId }.count
        } else if let targetRow = remainingRows.last {
            targetSectionId = targetRow.sectionId
            targetIndex = remainingRows.filter { $0.sectionId == targetSectionId }.count
        } else {
            targetSectionId = sourceRow.sectionId
            targetIndex = 0
        }

        return CmuxSidebarProviderWorkspaceMove(
            workspaceId: draggedWorkspaceId,
            sourceSectionId: sourceRow.sectionId,
            targetSectionId: targetSectionId,
            targetIndex: targetIndex
        )
    }

    static func preferredSectionId(
        targetWorkspaceId: UUID,
        indicator: SidebarDropIndicator?,
        orderedRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> String? {
        guard let targetIndex = orderedRows.firstIndex(where: { $0.workspaceId == targetWorkspaceId }) else {
            return nil
        }
        let targetRow = orderedRows[targetIndex]
        guard let indicator,
              let indicatorWorkspaceId = indicator.tabId,
              let indicatorIndex = orderedRows.firstIndex(where: { $0.workspaceId == indicatorWorkspaceId }) else {
            return targetRow.sectionId
        }
        if indicatorWorkspaceId == targetWorkspaceId {
            return targetRow.sectionId
        }
        if indicator.edge == .top, indicatorIndex == targetIndex + 1 {
            return targetRow.sectionId
        }
        return orderedRows[indicatorIndex].sectionId
    }

    static func sectionBoundaryIndicator(
        draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID,
        pointerY: CGFloat?,
        targetHeight: CGFloat?,
        orderedRows: [ExtensionSidebarBrowserStackDropRow]
    ) -> SidebarDropIndicator? {
        guard let draggedWorkspaceId,
              let sourceIndex = orderedRows.firstIndex(where: { $0.workspaceId == draggedWorkspaceId }),
              let targetIndex = orderedRows.firstIndex(where: { $0.workspaceId == targetWorkspaceId }),
              orderedRows[sourceIndex].sectionId != orderedRows[targetIndex].sectionId else {
            return nil
        }
        let edge: SidebarDropEdge
        if let pointerY, let targetHeight {
            edge = SidebarDropPlanner.edgeForPointer(locationY: pointerY, targetHeight: targetHeight)
        } else {
            edge = sourceIndex < targetIndex ? .top : .bottom
        }
        if sourceIndex + 1 == targetIndex, edge == .top {
            return SidebarDropIndicator(tabId: targetWorkspaceId, edge: .top)
        }
        if targetIndex + 1 == sourceIndex, edge == .bottom {
            return SidebarDropIndicator(tabId: targetWorkspaceId, edge: .bottom)
        }
        return nil
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
        return SidebarDropPlanner.indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetWorkspaceId,
            tabIds: workspaceIds,
            pinnedTabIds: [],
            pointerY: info.location.y,
            targetHeight: targetRowHeight
        ) ?? ExtensionSidebarBrowserStackDropPlanner.sectionBoundaryIndicator(
            draggedWorkspaceId: draggedTabId,
            targetWorkspaceId: targetWorkspaceId,
            pointerY: info.location.y,
            targetHeight: targetRowHeight,
            orderedRows: orderedRows
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
        ExtensionSidebarBrowserStackDropPlanner.move(
            draggedWorkspaceId: draggedWorkspaceId,
            insertionPosition: insertionPosition,
            orderedRows: orderedRows,
            preferredTargetSectionId: preferredTargetSectionId(indicator: indicator)
        )
    }

    private func preferredTargetSectionId(indicator: SidebarDropIndicator?) -> String? {
        ExtensionSidebarBrowserStackDropPlanner.preferredSectionId(
            targetWorkspaceId: targetWorkspaceId,
            indicator: indicator,
            orderedRows: orderedRows
        )
    }
}

struct ExtensionSidebarBrowserStackEndDropDelegate: DropDelegate {
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding var draggedTabId: UUID?
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
        updateDropIndicator()
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == nil {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId,
              let insertionPosition = insertionPositionForEndMove(draggedWorkspaceId: draggedTabId),
              let move = ExtensionSidebarBrowserStackDropPlanner.move(
                draggedWorkspaceId: draggedTabId,
                insertionPosition: insertionPosition,
                orderedRows: orderedRows
              ) else {
            return false
        }
        return onMove(move)
    }

    private func updateDropIndicator() {
        let workspaceIds = orderedRows.map(\.workspaceId)
        let nextIndicator = SidebarDropPlanner.indicator(
            draggedTabId: draggedTabId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        )
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func insertionPositionForEndMove(draggedWorkspaceId: UUID) -> Int? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        guard workspaceIds.contains(draggedWorkspaceId) else { return nil }
        guard SidebarDropPlanner.indicator(
            draggedTabId: draggedWorkspaceId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        ) != nil else {
            return nil
        }
        return workspaceIds.count
    }
}

struct MiddleClickCapture: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickCaptureView {
        let view = MiddleClickCaptureView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: MiddleClickCaptureView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}

final class MiddleClickCaptureView: NSView {
    var onMiddleClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept middle-click so left-click selection and right-click context menus
        // continue to hit-test through to SwiftUI/AppKit normally.
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown,
              event.buttonNumber == 2 else {
            return nil
        }
        return self
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick?()
    }
}
