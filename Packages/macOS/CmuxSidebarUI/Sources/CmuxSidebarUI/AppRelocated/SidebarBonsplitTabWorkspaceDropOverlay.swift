import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxWorkspaces
import CmuxFoundation
import SwiftUI

struct SidebarBonsplitTabWorkspaceDropOverlay: NSViewRepresentable {
    @MainActor
    final class TargetBridge {
        fileprivate weak var view: SidebarBonsplitTabWorkspaceDropView?
        fileprivate var targets: [SidebarDropPlanner.WorkspaceDropTarget] = []

        func updateTargets(_ targets: [SidebarDropPlanner.WorkspaceDropTarget]) {
            self.targets = targets
            guard !targets.isEmpty else { return }
            DispatchQueue.main.async { [weak view] in
                view?.performPendingDropIfPossible()
            }
        }

        func clearTargets() {
            targets = []
        }
    }

    struct TargetWriter: View {
        let targetBridge: TargetBridge
        let targets: [SidebarDropPlanner.WorkspaceDropTarget]

        var body: some View {
            Color.clear
                .onAppear {
                    targetBridge.updateTargets(targets)
                }
                .onChange(of: targets) { _, newTargets in
                    targetBridge.updateTargets(newTargets)
                }
                .onDisappear {
                    targetBridge.clearTargets()
                }
        }
    }

    let currentSelectedTabId: () -> UUID?
    let sidebarIndexForTabId: (UUID) -> Int?
    let moveToExistingWorkspace: (UUID, BonsplitTabDragPayload.Transfer) -> Bool
    let moveToNewWorkspace: (Int, BonsplitTabDragPayload.Transfer) -> UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var dropIndicator: SidebarDropIndicator?
    let updateAutoscroll: () -> Void
    let setWorkspaceDropTargetCollectionActive: (Bool) -> Void
    let isWorkspaceDropTargetCollectionActive: Bool
    let targetBridge: TargetBridge

    func makeNSView(context: Context) -> SidebarBonsplitTabWorkspaceDropView {
        SidebarBonsplitTabWorkspaceDropView()
    }

    func updateNSView(_ nsView: SidebarBonsplitTabWorkspaceDropView, context: Context) {
        targetBridge.view = nsView
        nsView.targetBridge = targetBridge
        nsView.canPerformAction = { action, transfer in
            guard let app = AppDelegate.shared else {
                return false
            }
            switch action {
            case .existingWorkspace(let workspaceId):
                if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
                   source.workspaceId == workspaceId {
                    return true
                }
                return app.canMoveBonsplitTab(tabId: transfer.tab.id, toWorkspace: workspaceId)
            case .newWorkspace:
                return app.canMoveBonsplitTabToNewWorkspace(tabId: transfer.tab.id)
            }
        }
        nsView.updateAutoscroll = updateAutoscroll
        nsView.setWorkspaceDropTargetCollectionActive = setWorkspaceDropTargetCollectionActive
        nsView.setDropIndicator = { indicator in
            dropIndicator = indicator
        }
        nsView.performExistingWorkspaceMove = { workspaceId, transfer in
            guard moveToExistingWorkspace(workspaceId, transfer) else { return false }
            selectedTabIds = [workspaceId]
            syncSidebarSelection(preferredSelectedTabId: workspaceId)
            return true
        }
        nsView.performNewWorkspaceMove = { insertionIndex, _, transfer in
            guard let destinationWorkspaceId = moveToNewWorkspace(insertionIndex, transfer) else { return false }
            selectedTabIds = [destinationWorkspaceId]
            syncSidebarSelection(preferredSelectedTabId: destinationWorkspaceId)
            return true
        }
        if !isWorkspaceDropTargetCollectionActive, targetBridge.targets.isEmpty {
            nsView.clearPendingDropIfIdle()
        }
        if !targetBridge.targets.isEmpty {
            DispatchQueue.main.async { [weak nsView] in
                nsView?.performPendingDropIfPossible()
            }
        }
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? currentSelectedTabId()
        if let selectedId {
            lastSidebarSelectionIndex = sidebarIndexForTabId(selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}

final class SidebarBonsplitTabWorkspaceDropView: NSView {
    private static let pasteboardType = NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)

    private struct PendingDrop {
        let requestId: UInt64
        let point: CGPoint
        let transfer: BonsplitTabDragPayload.Transfer
    }

    var targetBridge: SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge?
    var canPerformAction: (SidebarDropPlanner.WorkspaceDropAction, BonsplitTabDragPayload.Transfer) -> Bool = { _, _ in false }
    var updateAutoscroll: () -> Void = {}
    var setWorkspaceDropTargetCollectionActive: (Bool) -> Void = { _ in }
    var setDropIndicator: (SidebarDropIndicator?) -> Void = { _ in }
    var performExistingWorkspaceMove: (UUID, BonsplitTabDragPayload.Transfer) -> Bool = { _, _ in false }
    var performNewWorkspaceMove: (Int, SidebarDropIndicator, BonsplitTabDragPayload.Transfer) -> Bool = { _, _, _ in false }
    private var isRequestingWorkspaceDropTargets = false
    private var workspaceDropTargetRequestId: UInt64 = 0
    private var pendingDrop: PendingDrop?
    private var targets: [SidebarDropPlanner.WorkspaceDropTarget] {
        targetBridge?.targets ?? []
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.pasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        shouldCaptureHitTest() ? super.hitTest(point) : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateWorkspaceDropTargetCollection(sender, isActive: true)
        return updateDrag(sender, phase: "entered")
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateWorkspaceDropTargetCollection(sender, isActive: true)
        return updateDrag(sender, phase: "updated")
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        guard pendingDrop == nil else {
            completeOrClearPendingDropAfterDragTeardown()
            setDropIndicator(nil)
            return
        }
        updateWorkspaceDropTargetCollection(sender, isActive: false)
#if DEBUG
        dlog("sidebar.workspaceDropOverlay.exited clear=1")
#endif
        setDropIndicator(nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let action = action(for: sender)
        let accepted = acceptedTransfer(sender, action: action) != nil || pendingTransfer(sender) != nil
#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.prepare accepted=\(accepted ? 1 : 0) " +
            "action=\(debugActionDescription(action))"
        )
#endif
        return accepted
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let action = action(for: sender)
        if let action, let transfer = acceptedTransfer(sender, action: action) {
            let moved = perform(action: action, transfer: transfer)
            pendingDrop = nil
            updateWorkspaceDropTargetCollection(sender, isActive: false)
            setDropIndicator(nil)
#if DEBUG
            dlog(
                "sidebar.workspaceDropOverlay.perform moved=\(moved ? 1 : 0) " +
                "action=\(debugActionDescription(action))"
            )
#endif
            return moved
        }

        if let transfer = pendingTransfer(sender) {
            pendingDrop = PendingDrop(
                requestId: workspaceDropTargetRequestId,
                point: localPoint(sender),
                transfer: transfer
            )
#if DEBUG
            dlog("sidebar.workspaceDropOverlay.perform pendingTargets=1")
#endif
            return true
        }

        updateWorkspaceDropTargetCollection(sender, isActive: false)
        setDropIndicator(nil)
#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.perform moved=0 reason=notAccepted " +
            "action=\(debugActionDescription(action))"
        )
#endif
        return false
    }

    func performPendingDropIfPossible() {
        guard let pendingDrop,
              pendingDrop.requestId == workspaceDropTargetRequestId,
              isRequestingWorkspaceDropTargets,
              !targets.isEmpty else {
            return
        }
        self.pendingDrop = nil
        defer {
            updateWorkspaceDropTargetCollection(nil, isActive: false)
            setDropIndicator(nil)
        }

        guard let action = SidebarDropPlanner().workspaceAction(for: pendingDrop.point, targets: targets),
              canPerformAction(action, pendingDrop.transfer) else {
#if DEBUG
            dlog("sidebar.workspaceDropOverlay.performPending moved=0 reason=notAccepted")
#endif
            return
        }

        let moved = perform(action: action, transfer: pendingDrop.transfer)
#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.performPending moved=\(moved ? 1 : 0) " +
            "action=\(debugActionDescription(action))"
        )
#endif
    }

    func clearPendingDrop() {
        pendingDrop = nil
        isRequestingWorkspaceDropTargets = false
        workspaceDropTargetRequestId &+= 1
    }

    func clearPendingDropIfIdle() {
        guard !isRequestingWorkspaceDropTargets else { return }
        clearPendingDrop()
    }

    private func perform(
        action: SidebarDropPlanner.WorkspaceDropAction,
        transfer: BonsplitTabDragPayload.Transfer
    ) -> Bool {
        switch action {
        case .existingWorkspace(let workspaceId):
            return performExistingWorkspaceMove(workspaceId, transfer)
        case .newWorkspace(let insertionIndex, let indicator):
            return performNewWorkspaceMove(insertionIndex, indicator, transfer)
        }
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        guard pendingDrop == nil else {
            completeOrClearPendingDropAfterDragTeardown()
            setDropIndicator(nil)
            return
        }
        updateWorkspaceDropTargetCollection(sender, isActive: false)
#if DEBUG
        dlog("sidebar.workspaceDropOverlay.concluded clear=1")
#endif
        setDropIndicator(nil)
    }

    private func updateDrag(_ sender: any NSDraggingInfo, phase: String) -> NSDragOperation {
        let action = action(for: sender)
        if isRequestingWorkspaceDropTargets,
           targets.isEmpty,
           BonsplitTabDragPayload.transfer(from: sender.draggingPasteboard) != nil {
            setDropIndicator(nil)
#if DEBUG
            dlog("sidebar.workspaceDropOverlay.\(phase) accepted=1 pendingTargets=1")
#endif
            return .move
        }
        guard acceptedTransfer(sender, action: action) != nil, let action else {
            setDropIndicator(nil)
#if DEBUG
            dlog(
                "sidebar.workspaceDropOverlay.\(phase) accepted=0 clear=1 " +
                "action=\(debugActionDescription(action))"
            )
#endif
            return []
        }

        updateAutoscroll()
        switch action {
        case .newWorkspace(_, let indicator):
            setDropIndicator(indicator)
        case .existingWorkspace:
            setDropIndicator(nil)
        }

#if DEBUG
        dlog(
            "sidebar.workspaceDropOverlay.\(phase) accepted=1 " +
            "action=\(debugActionDescription(action))"
        )
#endif
        return .move
    }

    private func completeOrClearPendingDropAfterDragTeardown() {
        completeOrClearPendingDropAfterDragTeardown(remainingFrameWaits: 3)
    }

    private func completeOrClearPendingDropAfterDragTeardown(remainingFrameWaits: Int) {
        let requestId = workspaceDropTargetRequestId
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.pendingDrop?.requestId == requestId else {
                return
            }

            if self.targets.isEmpty, remainingFrameWaits > 0 {
                self.completeOrClearPendingDropAfterDragTeardown(
                    remainingFrameWaits: remainingFrameWaits - 1
                )
                return
            }

            self.performPendingDropIfPossible()
            guard self.pendingDrop?.requestId == requestId else { return }

            self.clearPendingDrop()
            self.setWorkspaceDropTargetCollectionActive(false)
            self.setDropIndicator(nil)
#if DEBUG
            dlog("sidebar.workspaceDropOverlay.pendingTeardown clear=1")
#endif
        }
    }

    private func updateWorkspaceDropTargetCollection(
        _ sender: (any NSDraggingInfo)?,
        isActive: Bool
    ) {
        let shouldRequestTargets = isActive && BonsplitTabDragPayload.canRouteWorkspaceDrop(
            pasteboardTypes: sender?.draggingPasteboard.types
        )
        if !shouldRequestTargets {
            pendingDrop = nil
        }
        if shouldRequestTargets, !isRequestingWorkspaceDropTargets {
            workspaceDropTargetRequestId &+= 1
        }
        isRequestingWorkspaceDropTargets = shouldRequestTargets
        setWorkspaceDropTargetCollectionActive(shouldRequestTargets)
    }

    private func acceptedTransfer(
        _ sender: any NSDraggingInfo,
        action: SidebarDropPlanner.WorkspaceDropAction?
    ) -> BonsplitTabDragPayload.Transfer? {
        let pasteboard = sender.draggingPasteboard
        guard pasteboard.types?.contains(Self.pasteboardType) == true,
              let transfer = BonsplitTabDragPayload.transfer(from: pasteboard),
              let action,
              canPerformAction(action, transfer) else {
            return nil
        }
        return transfer
    }

    private func pendingTransfer(_ sender: any NSDraggingInfo) -> BonsplitTabDragPayload.Transfer? {
        guard isRequestingWorkspaceDropTargets, targets.isEmpty else { return nil }
        return BonsplitTabDragPayload.transfer(from: sender.draggingPasteboard)
    }

    private func action(for sender: any NSDraggingInfo) -> SidebarDropPlanner.WorkspaceDropAction? {
        SidebarDropPlanner().workspaceAction(for: localPoint(sender), targets: targets)
    }

    private func shouldCaptureHitTest() -> Bool {
        let eventType = NSApp.currentEvent?.type
        guard WindowInputRoutingContext.allowsWorkspaceDropOverlayHitTesting(eventType: eventType) else {
            return false
        }
        guard BonsplitTabDragPayload.canRouteWorkspaceDrop(
            pasteboardTypes: NSPasteboard(name: .drag).types
        ) else { return false }
        return true
    }

    private func localPoint(_ sender: any NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }

#if DEBUG
    private func debugActionDescription(_ action: SidebarDropPlanner.WorkspaceDropAction?) -> String {
        guard let action else { return "nil" }
        switch action {
        case .existingWorkspace(let workspaceId):
            return "existing:\(debugShortId(workspaceId))"
        case .newWorkspace(let insertionIndex, let indicator):
            return "new:index=\(insertionIndex),indicator=\(debugIndicatorDescription(indicator))"
        }
    }

    private func debugIndicatorDescription(_ indicator: SidebarDropIndicator) -> String {
        let target = indicator.tabId.map(debugShortId) ?? "end"
        let edge = indicator.edge == .top ? "top" : "bottom"
        return "\(target):\(edge)"
    }

    private func debugShortId(_ id: UUID) -> String {
        String(id.uuidString.prefix(5))
    }
#endif
}
