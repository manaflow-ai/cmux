import AppKit
import CmuxTerminalCore

extension GhosttyNSView {
    enum ClipboardDeferredInput {
        case appKitEvent(NSEvent)
        case runtimeMutation(() -> Void)
    }

    func beginClipboardRead(
        _ requestID: UInt,
        inputAdmission: RuntimeClipboardInputAdmission,
        onOverflow: @escaping () -> Void
    ) {
        switch inputAdmission {
        case .unsequenced(let epoch):
            terminalClipboardInputSequencer.beginUnsequencedRequest(
                id: requestID,
                epoch: epoch
            )
        case .reserved(let epoch):
            terminalClipboardInputSequencer.beginReservedRequest(
                id: requestID,
                onOverflow: { [weak self] in
                    guard let self else {
                        onOverflow()
                        return
                    }
                    cancelClipboardRead(
                        requestID,
                        currentEpoch: terminalSurface?
                            .runtimeSurfaceGeneration ?? epoch,
                        deferredInputDisposition: .replay
                    )
                    onOverflow()
                }
            )
        }
    }

    func clipboardReadRequiresConfirmation(
        _ requestID: UInt
    ) {
        terminalClipboardInputSequencer.requireConfirmation(
            for: requestID
        )
    }

    func performClipboardReadCompletionWhenReady(
        _ requestID: UInt,
        _ completion: @escaping () -> Void
    ) {
        terminalClipboardInputSequencer.performCompletionWhenReady(
            id: requestID,
            completion
        )
    }

    func completeClipboardRead(
        _ requestID: UInt,
        confirmed: Bool,
        onLogicalCompletion: () -> Void = {}
    ) {
        terminalClipboardInputSequencer.completeRequest(
            id: requestID,
            confirmed: confirmed,
            onLogicalCompletion: onLogicalCompletion
        ) { [weak self] deferredInput in
            self?.replayClipboardDeferredInput(deferredInput)
        }
        scheduleMouseRepairAfterClipboardDrainIfNeeded()
    }

    func cancelClipboardRead(
        _ requestID: UInt,
        currentEpoch: UInt64,
        deferredInputDisposition: RuntimeClipboardDeferredInputDisposition
    ) {
        terminalClipboardInputSequencer.cancelRequest(
            id: requestID,
            currentEpoch: currentEpoch,
            deferredInputDisposition: deferredInputDisposition
        ) { [weak self] deferredInput in
            self?.replayClipboardDeferredInput(deferredInput)
        }
        scheduleMouseRepairAfterClipboardDrainIfNeeded()
    }

    func cancelReservedClipboardRead(
        _ requestID: UInt,
        requestEpoch: UInt64,
        currentEpoch: UInt64,
        deferredInputDisposition: RuntimeClipboardDeferredInputDisposition
    ) {
        terminalClipboardInputSequencer.cancelReservedRequest(
            id: requestID,
            requestEpoch: requestEpoch,
            currentEpoch: currentEpoch,
            deferredInputDisposition: deferredInputDisposition
        ) { [weak self] deferredInput in
            self?.replayClipboardDeferredInput(deferredInput)
        }
        scheduleMouseRepairAfterClipboardDrainIfNeeded()
    }

    private func scheduleMouseRepairAfterClipboardDrainIfNeeded() {
        guard !hasClipboardInputDeferral else { return }
        scheduleGhosttyMouseButtonRepair(reason: "clipboardInputDrained")
    }

    func routeInputDuringClipboardRead(_ event: NSEvent) -> Bool {
        terminalClipboardInputSequencer.shouldDefer(
            .appKitEvent(event),
            epoch: terminalSurface?.runtimeSurfaceGeneration ?? .max,
            discardWhenFull: event.cmuxCanDiscardDuringClipboardRead
        )
    }

    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes: Int,
        replay: @escaping () -> Void
    ) -> Bool {
        terminalClipboardInputSequencer.shouldDefer(
            .runtimeMutation(replay),
            epoch: terminalSurface?.runtimeSurfaceGeneration ?? .max,
            estimatedCost: estimatedBytes
        )
    }

    func withPotentialClipboardPasteIntent<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        guard let terminalSurface else { return try body() }
        return try terminalSurface.withRuntimeClipboardPasteIntent(body)
    }

    private func replayClipboardDeferredInput(
        _ deferredInput: ClipboardDeferredInput
    ) {
        switch deferredInput {
        case .appKitEvent(let event):
            replayClipboardDeferredEvent(event)
        case .runtimeMutation(let replay):
            replay()
        }
    }

    private func replayClipboardDeferredEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            keyDown(with: event)
        case .keyUp:
            keyUp(with: event)
        case .flagsChanged:
            flagsChanged(with: event)
        case .leftMouseDown:
            mouseDown(with: event)
        case .leftMouseUp:
            mouseUp(with: event)
        case .rightMouseDown:
            rightMouseDown(with: event)
        case .rightMouseUp:
            rightMouseUp(with: event)
        case .otherMouseDown:
            otherMouseDown(with: event)
        case .otherMouseUp:
            otherMouseUp(with: event)
        case .mouseMoved:
            mouseMoved(with: event)
        case .mouseEntered:
            mouseEntered(with: event)
        case .mouseExited:
            mouseExited(with: event)
        case .leftMouseDragged:
            mouseDragged(with: event)
        case .rightMouseDragged:
            rightMouseDragged(with: event)
        case .otherMouseDragged:
            otherMouseDragged(with: event)
        case .scrollWheel:
            scrollWheel(with: event)
        default:
            assertionFailure("Unsupported clipboard-sequenced input event")
        }
    }
}

private extension NSEvent {
    var cmuxCanDiscardDuringClipboardRead: Bool {
        switch type {
        case .mouseMoved,
             .mouseEntered,
             .mouseExited,
             .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged,
             .scrollWheel:
            return true
        default:
            return false
        }
    }
}
