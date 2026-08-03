import AppKit
import Bonsplit
import CmuxFoundation
@MainActor
enum SidebarBonsplitTabWorkspaceDropOverlay {
    final class TargetBridge {
        fileprivate weak var view: SidebarBonsplitTabWorkspaceDropView?
        fileprivate var targets = SidebarDropPlanner.OrderedWorkspaceDropTargets([])
        private var pendingTargetDeliveryTask: Task<Void, Never>?

        func attach(_ view: SidebarBonsplitTabWorkspaceDropView) {
            self.view = view
        }

        func detach(_ view: SidebarBonsplitTabWorkspaceDropView) {
            guard self.view === view else { return }
            self.view = nil
            pendingTargetDeliveryTask?.cancel()
            pendingTargetDeliveryTask = nil
        }

        func updateTargets(_ targets: [SidebarDropPlanner.WorkspaceDropTarget]) {
            self.targets = SidebarDropPlanner.OrderedWorkspaceDropTargets(targets)
            pendingTargetDeliveryTask?.cancel()
            guard !self.targets.isEmpty else {
                pendingTargetDeliveryTask = nil
                return
            }
            pendingTargetDeliveryTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.view?.performPendingDropIfPossible()
                self?.pendingTargetDeliveryTask = nil
            }
        }

        func clearTargets() {
            pendingTargetDeliveryTask?.cancel()
            pendingTargetDeliveryTask = nil
            targets = SidebarDropPlanner.OrderedWorkspaceDropTargets([])
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

    var targetBridge: SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge? {
        didSet {
            oldValue?.detach(self)
            targetBridge?.attach(self)
        }
    }
    var canPerformAction: (SidebarDropPlanner.WorkspaceDropAction, BonsplitTabDragPayload.Transfer) -> Bool = { _, _ in false }
    var updateAutoscroll: () -> Void = {}
    var setWorkspaceDropTargetCollectionActive: (Bool) -> Void = { _ in }
    var setDropIndicator: (SidebarDropIndicator?) -> Void = { _ in }
    var performExistingWorkspaceMove: (UUID, BonsplitTabDragPayload.Transfer) -> Bool = { _, _ in false }
    var performNewWorkspaceMove: (Int, SidebarDropIndicator, BonsplitTabDragPayload.Transfer) -> Bool = { _, _, _ in false }
    private var isRequestingWorkspaceDropTargets = false
    private var workspaceDropTargetRequestId: UInt64 = 0
    private var pendingDrop: PendingDrop?
    private var pendingTeardownTask: Task<Void, Never>?
    private var targets: SidebarDropPlanner.OrderedWorkspaceDropTargets {
        targetBridge?.targets ?? SidebarDropPlanner.OrderedWorkspaceDropTargets([])
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// Retires drag state before a retained presentation is hidden or disconnected.
    func suspendPresentation() {
        pendingTeardownTask?.cancel()
        pendingTeardownTask = nil
        pendingDrop = nil
        isRequestingWorkspaceDropTargets = false
        setWorkspaceDropTargetCollectionActive(false)
        setDropIndicator(nil)
        targetBridge?.clearTargets()
    }

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
        let requestId = workspaceDropTargetRequestId
        pendingTeardownTask?.cancel()
        pendingTeardownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<3 {
                await Task.yield()
                guard !Task.isCancelled,
                      self.pendingDrop?.requestId == requestId else {
                    return
                }
                if !self.targets.isEmpty { break }
            }

            self.performPendingDropIfPossible()
            guard self.pendingDrop?.requestId == requestId else { return }

            self.clearPendingDrop()
            self.setWorkspaceDropTargetCollectionActive(false)
            self.setDropIndicator(nil)
#if DEBUG
            dlog("sidebar.workspaceDropOverlay.pendingTeardown clear=1")
#endif
            self.pendingTeardownTask = nil
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
