import AppKit

extension GhosttyNSView {
    nonisolated func reserveClipboardReadAdmission() {
        terminalClipboardInputSequencer.reserveRequestAdmission()
    }

    func beginReservedClipboardRead(_ requestID: UInt) {
        terminalClipboardInputSequencer.beginReservedRequest(id: requestID)
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

    func routeInputDuringClipboardRead(_ event: NSEvent) -> Bool {
        terminalClipboardInputSequencer.shouldDefer(
            event,
            replay: { [weak self] event in
                self?.replayClipboardDeferredInput(event)
            }
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
        default:
            assertionFailure("Only keyboard events enter clipboard sequencing")
        }
    }
}
