import AppKit

@MainActor
final class SidebarWorkspaceReorderDropView: NSView {
    var targets: [SidebarWorkspaceReorderDropOverlay.Target] = []
    var isValidDrag: (() -> Bool)?
    var updateDrag: ((CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool)?
    var performDropAtPoint: ((CGPoint, [SidebarWorkspaceReorderDropOverlay.Target]) -> Bool)?
    var clearDropIndicator: (() -> Void)?
    var setWorkspaceDropTargetCollectionActive: ((Bool) -> Void)?
    private var isRequestingTargets = false
    private var targetRequestId: UInt64 = 0
    private var pendingDrop: SidebarWorkspaceReorderPendingDrop?

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
        setTargetCollectionActive(true)
        return update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        setTargetCollectionActive(true)
        return update(sender)
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
        let point = convert(sender.draggingLocation, from: nil)
        guard !targets.isEmpty else {
            pendingDrop = SidebarWorkspaceReorderPendingDrop(requestId: targetRequestId, point: point)
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

    func performPendingDropIfPossible() {
        guard let pendingDrop,
              pendingDrop.requestId == targetRequestId,
              isRequestingTargets,
              !targets.isEmpty,
              let performDropAtPoint else {
            return
        }
        self.pendingDrop = nil
        let performed = performDropAtPoint(pendingDrop.point, targets)
        setTargetCollectionActive(false)
        if !performed {
            clearDropIndicator?()
        }
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender), let updateDrag else { return [] }
        guard !targets.isEmpty else {
            clearDropIndicator?()
            return .move
        }
        let point = convert(sender.draggingLocation, from: nil)
        return updateDrag(point, targets) ? .move : []
    }

    private func setTargetCollectionActive(_ isActive: Bool) {
        if isActive, !isRequestingTargets {
            targetRequestId &+= 1
        }
        if !isActive {
            pendingDrop = nil
        }
        isRequestingTargets = isActive
        setWorkspaceDropTargetCollectionActive?(isActive)
    }

    private func completeOrClearPendingDropAfterDragTeardown() {
        completeOrClearPendingDropAfterDragTeardown(remainingFrameWaits: 3)
    }

    private func completeOrClearPendingDropAfterDragTeardown(remainingFrameWaits: Int) {
        guard let pendingDrop else { return }
        let requestId = pendingDrop.requestId
        Task { @MainActor [weak self] in
            await Task.yield()
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
            self.setTargetCollectionActive(false)
            self.clearDropIndicator?()
        }
    }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.types?.contains(SidebarWorkspaceReorderDropOverlay.pasteboardType) == true else {
            return false
        }
        return isValidDrag?() == true
    }

    private func acceptsCurrentDragPasteboard() -> Bool {
        SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
            eventType: NSApp.currentEvent?.type,
            pasteboardTypes: NSPasteboard(name: .drag).types
        )
    }

    private func shouldCaptureHitTest() -> Bool {
        acceptsCurrentDragPasteboard()
    }
}
