import AppKit

extension GhosttyNSView {
    func beginReservedClipboardRead(
        _ requestID: UInt,
        epoch: UInt64,
        onOverflow: @escaping () -> Void
    ) {
        terminalClipboardInputSequencer.beginReservedRequest(
            id: requestID,
            epoch: epoch,
            onOverflow: onOverflow
        )
    }

    func clipboardReadRequiresConfirmation(
        _ requestID: UInt
    ) {
        terminalClipboardInputSequencer.requireConfirmation(
            for: requestID
        )
    }

    func completeClipboardRead(
        _ requestID: UInt,
        confirmed: Bool
    ) {
        terminalClipboardInputSequencer.completeRequest(
            id: requestID,
            confirmed: confirmed
        ) { [weak self] event in
            self?.replayClipboardDeferredInput(event)
        }
    }

    func cancelClipboardRead(
        _ requestID: UInt,
        currentEpoch: UInt64
    ) {
        terminalClipboardInputSequencer.cancelRequest(
            id: requestID,
            currentEpoch: currentEpoch
        ) { [weak self] event in
            self?.replayClipboardDeferredInput(event)
        }
    }

    func cancelReservedClipboardRead(
        _ requestID: UInt,
        currentEpoch: UInt64
    ) {
        terminalClipboardInputSequencer.cancelReservedRequest(
            id: requestID,
            currentEpoch: currentEpoch
        ) { [weak self] event in
            self?.replayClipboardDeferredInput(event)
        }
    }

    func routeInputDuringClipboardRead(_ event: NSEvent) -> Bool {
        terminalClipboardInputSequencer.shouldDefer(
            event,
            epoch: terminalSurface?.runtimeSurfaceGeneration ?? .max,
            discardWhenFull: event.cmuxCanDiscardDuringClipboardRead
        )
    }

    private func replayClipboardDeferredInput(_ event: NSEvent) {
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
