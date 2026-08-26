import AppKit

@MainActor
final class SidebarWorkspaceReorderDropView: NSView {
    var targets: [SidebarWorkspaceReorderDropOverlay.Target] = []
    var isValidDrag: (() -> Bool)?
    var updateDrag: ((CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool)?
    var performDropAtPoint: ((CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool)?
    /// Optional commit path for a drop accepted before targets were available.
    /// It receives the immutable drag identity captured at acceptance so the
    /// native source may finish before the deferred target update arrives.
    var performPendingDropAtPoint: ((SidebarWorkspaceReorderPendingDrop, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool)?
    var clearDropIndicator: (() -> Void)?
    var setWorkspaceDropTargetCollectionActive: ((Bool) -> Void)?
    var hasLiveWorkspaceDrag: (() -> Bool)?
    var pointOffset: CGSize = .zero
    private var isRequestingTargets = false
    private var targetRequestId: UInt64 = 0
    private var pendingDrop: SidebarWorkspaceReorderPendingDrop?
    private var awaitsTargetsAfterDragTeardown = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shouldCaptureHitTest() else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = update(sender)
        setTargetCollectionActive(operation != [])
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = update(sender)
        setTargetCollectionActive(operation != [])
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard pendingDrop == nil else {
            completeOrClearPendingDropAfterDragTeardown()
            clearDropIndicator?()
            return
        }
        setTargetCollectionActive(false)
        clearDropIndicator?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender), let performDropAtPoint else { return false }
        let point = dropPoint(from: sender)
        guard !targets.isEmpty else {
            setTargetCollectionActive(true)
            awaitsTargetsAfterDragTeardown = false
            let pasteboard = sender.draggingPasteboard
            let rawPayload = SidebarTabDragPayload.pasteboardString(from: pasteboard)
            pendingDrop = SidebarWorkspaceReorderPendingDrop(
                requestId: targetRequestId,
                point: point,
                workspaceId: SidebarTabDragPayload.workspaceId(fromPasteboardString: rawPayload),
                sessionId: SidebarTabDragPayload.sessionId(fromPasteboardString: rawPayload)
            )
            return true
        }
        let performed = performDropAtPoint(point, targets)
        pendingDrop = nil
        setTargetCollectionActive(false)
        if !performed {
            clearDropIndicator?()
        }
        return performed
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        guard pendingDrop == nil else {
            completeOrClearPendingDropAfterDragTeardown()
            clearDropIndicator?()
            return
        }
        setTargetCollectionActive(false)
    }

    func suspendPresentation() {
        setTargetCollectionActive(false)
        targets = []
    }

    func performPendingDropIfPossible() {
        guard let pendingDrop,
              pendingDrop.requestId == targetRequestId,
              isRequestingTargets,
              !targets.isEmpty,
              let performDropAtPoint else {
            return
        }
        self.pendingDrop = nil
        awaitsTargetsAfterDragTeardown = false
        let performed: Bool
        if let performPendingDropAtPoint {
            performed = performPendingDropAtPoint(pendingDrop, targets)
        } else {
            performed = performDropAtPoint(pendingDrop.point, targets)
        }
        setTargetCollectionActive(false)
        if !performed {
            clearDropIndicator?()
        }
    }

    func targetsDidUpdate() {
        guard pendingDrop != nil else { return }
        guard !targets.isEmpty else {
            clearPendingDropAfterEmptyTargetCollectionIfNeeded()
            return
        }
        performPendingDropIfPossible()
    }

    private func completeOrClearPendingDropAfterDragTeardown() {
        awaitsTargetsAfterDragTeardown = pendingDrop != nil
    }

    private func clearPendingDropAfterEmptyTargetCollectionIfNeeded() {
        guard awaitsTargetsAfterDragTeardown else { return }
        awaitsTargetsAfterDragTeardown = false
        setTargetCollectionActive(false)
        clearDropIndicator?()
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender), let updateDrag else { return [] }
        guard !targets.isEmpty else {
            clearDropIndicator?()
            return .move
        }
        let point = dropPoint(from: sender)
        return updateDrag(point, targets) ? .move : []
    }

    func dropPoint(from sender: NSDraggingInfo) -> CGPoint {
        let point = convert(sender.draggingLocation, from: nil)
        return CGPoint(x: point.x + pointOffset.width, y: point.y + pointOffset.height)
    }

    private func setTargetCollectionActive(_ isActive: Bool) {
        guard isRequestingTargets != isActive else { return }
        if isActive, !isRequestingTargets {
            targetRequestId &+= 1
        }
        if !isActive {
            pendingDrop = nil
            awaitsTargetsAfterDragTeardown = false
        }
        isRequestingTargets = isActive
        setWorkspaceDropTargetCollectionActive?(isActive)
    }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.types?.contains(SidebarWorkspaceReorderDropOverlay.pasteboardType) == true else {
            return false
        }
        return hasLiveWorkspaceDrag?() == true && isValidDrag?() == true
    }

    private func acceptsCurrentDragPasteboard() -> Bool {
        SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
            eventType: NSApp.currentEvent?.type,
            pasteboardTypes: NSPasteboard(name: .drag).types,
            hasLiveWorkspaceDrag: hasLiveWorkspaceDrag?() == true
        )
    }

    private func shouldCaptureHitTest() -> Bool {
        acceptsCurrentDragPasteboard()
    }
}
