import AppKit

@MainActor
final class SidebarWorkspaceReorderDropView: NSView {
    private typealias DragIdentity = (
        workspaceId: UUID?,
        sessionId: UUID?,
        sequenceNumber: Int
    )

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
    /// Called after a deferred payload is committed or invalidated. The table
    /// controller uses this to release a retained reconstructed container only
    /// after its pending operation is no longer needed.
    var onPendingDropLifecycleEnded: (() -> Void)?
    var pointOffset: CGSize = .zero
    private var isRequestingTargets = false
    private var targetRequestId: UInt64 = 0
    private var pendingDrop: SidebarWorkspaceReorderPendingDrop?
    private var awaitsTargetsAfterDragTeardown = false
    private var activeDragIdentity: DragIdentity?

    var hasPendingDrop: Bool { pendingDrop != nil }

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
        prepareForDrag(sender)
        let operation = update(sender)
        setTargetCollectionActive(operation != [])
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        prepareForDrag(sender)
        let operation = update(sender)
        setTargetCollectionActive(operation != [])
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard isCurrentDrag(sender) else { return }
        guard pendingDrop == nil else {
            completeOrClearPendingDropAfterDragTeardown()
            clearDropIndicator?()
            return
        }
        setTargetCollectionActive(false)
        clearDropIndicator?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        prepareForDrag(sender)
        guard accepts(sender), let performDropAtPoint else { return false }
        let point = dropPoint(from: sender)
        guard !targets.isEmpty else {
            setTargetCollectionActive(true)
            awaitsTargetsAfterDragTeardown = false
            let pasteboard = sender.draggingPasteboard
            let rawPayload = SidebarTabDragPayload.pasteboardString(from: pasteboard)
            invalidatePendingDrop()
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
        guard isCurrentDrag(sender) else { return }
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
        guard let pendingDrop else { return }
        guard pendingDrop.requestId == targetRequestId else {
            invalidatePendingDrop()
            return
        }
        guard isRequestingTargets,
              !targets.isEmpty,
              let performDropAtPoint else {
            return
        }
        let requestId = pendingDrop.requestId
        self.pendingDrop = nil
        awaitsTargetsAfterDragTeardown = false
        defer { onPendingDropLifecycleEnded?() }
        let performed: Bool
        if let performPendingDropAtPoint {
            performed = performPendingDropAtPoint(pendingDrop, targets)
        } else {
            performed = performDropAtPoint(pendingDrop.point, targets)
        }
        // A callback can synchronously cause another drag to enter. Do not
        // turn off that newer request's target collection when retiring this
        // completed generation.
        guard targetRequestId == requestId else { return }
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

    /// Invalidates a deferred operation when a newer native drag supersedes
    /// the completed source. The detached view must not keep its old target
    /// request active or commit that older generation later.
    func invalidatePendingDropForNewNativeSession() {
        let hadPendingDrop = pendingDrop != nil
        pendingDrop = nil
        awaitsTargetsAfterDragTeardown = false
        activeDragIdentity = nil
        targetRequestId &+= 1
        if isRequestingTargets {
            isRequestingTargets = false
            setWorkspaceDropTargetCollectionActive?(false)
        }
        if hadPendingDrop {
            onPendingDropLifecycleEnded?()
        }
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
            let hadPendingDrop = pendingDrop != nil
            pendingDrop = nil
            awaitsTargetsAfterDragTeardown = false
            activeDragIdentity = nil
            if hadPendingDrop {
                onPendingDropLifecycleEnded?()
            }
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

    private func prepareForDrag(_ sender: NSDraggingInfo) {
        let nextIdentity = dragIdentity(for: sender)
        if let activeDragIdentity, activeDragIdentity == nextIdentity {
            return
        }

        if activeDragIdentity != nil {
            // A new native drag supersedes any deferred operation from the
            // previous sequence. Invalidate its request without toggling the
            // shared target collection off, so the new drag remains active.
            invalidatePendingDrop()
            targetRequestId &+= 1
            if !isRequestingTargets {
                isRequestingTargets = true
                setWorkspaceDropTargetCollectionActive?(true)
            }
        }
        activeDragIdentity = nextIdentity
    }

    private func invalidatePendingDrop() {
        let hadPendingDrop = pendingDrop != nil
        pendingDrop = nil
        awaitsTargetsAfterDragTeardown = false
        if hadPendingDrop {
            onPendingDropLifecycleEnded?()
        }
    }

    private func isCurrentDrag(_ sender: NSDraggingInfo?) -> Bool {
        guard let sender, let activeDragIdentity else { return true }
        return activeDragIdentity == dragIdentity(for: sender)
    }

    private func dragIdentity(for sender: NSDraggingInfo) -> DragIdentity {
        DragIdentity(
            workspaceId: SidebarTabDragPayload.workspaceId(
                fromPasteboardString: SidebarTabDragPayload.pasteboardString(from: sender.draggingPasteboard)
            ),
            sessionId: SidebarTabDragPayload.sessionId(from: sender.draggingPasteboard),
            sequenceNumber: sender.draggingSequenceNumber
        )
    }
}
