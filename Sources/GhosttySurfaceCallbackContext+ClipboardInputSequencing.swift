import AppKit
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit

extension GhosttySurfaceCallbackContext {
    func registerRuntimeClipboardRead(
        id: UInt,
        stateAddress: UInt,
        operation: TerminalImageTransferOperation,
        surfaceView: GhosttyNSView?
    ) -> UInt? {
        guard let surfaceAddress = runtimeClipboardSurfaceAddress else {
            return nil
        }
        let inputSequencer = surfaceView?.terminalClipboardInputSequencer
        let overflowHandler = makeRuntimeClipboardInvalidationHandler(
            for: id,
            completingNativeRequest: true,
            deferredInputDisposition: .replay
        )
        guard registerRuntimeClipboardRequest(
            id: id,
            reservePasteInput: { epoch in
                guard let inputSequencer else { return false }
                return inputSequencer.reserveRequestAdmission(
                    id: id,
                    epoch: epoch,
                    onOverflow: overflowHandler
                )
            },
            onInvalidation: {
                @MainActor [weak surfaceView]
                wasAdmitted,
                completesNativeRequest,
                inputAdmission,
                deferredInputDisposition in
                _ = operation.cancel()
                surfaceView?.terminalSurface?.hostedView
                    .endImageTransferIndicator(for: operation)
                if completesNativeRequest,
                   let surface = ghostty_surface_t(
                    bitPattern: surfaceAddress
                   ) {
                    // Teardown cannot present a confirmation prompt; approving
                    // empty text guarantees libghostty destroys its request.
                    "".withCString { pointer in
                        ghostty_surface_complete_clipboard_request(
                            surface,
                            pointer,
                            UnsafeMutableRawPointer(
                                bitPattern: stateAddress
                            ),
                            true
                        )
                    }
                }

                let currentEpoch = surfaceView?.terminalSurface?
                    .runtimeSurfaceGeneration ?? .max
                if wasAdmitted {
                    surfaceView?.cancelClipboardRead(
                        id,
                        currentEpoch: currentEpoch,
                        deferredInputDisposition: deferredInputDisposition
                    )
                } else if case .reserved(let requestEpoch) = inputAdmission {
                    surfaceView?.cancelReservedClipboardRead(
                        id,
                        requestEpoch: requestEpoch,
                        currentEpoch: currentEpoch,
                        deferredInputDisposition: deferredInputDisposition
                    )
                }
            }
        ) else {
            return nil
        }
        return surfaceAddress
    }

    @MainActor
    func completeRuntimeClipboardRead(
        _ text: String,
        requestID: UInt,
        stateAddress: UInt,
        surfaceAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity
    ) {
        guard let surfaceView else {
            finishRuntimeClipboardRead(
                text,
                requestID: requestID,
                stateAddress: stateAddress,
                surfaceAddress: surfaceAddress,
                surfaceIdentity: surfaceIdentity
            )
            return
        }
        surfaceView.performClipboardReadCompletionWhenReady(requestID) {
            self.finishRuntimeClipboardRead(
                text,
                requestID: requestID,
                stateAddress: stateAddress,
                surfaceAddress: surfaceAddress,
                surfaceIdentity: surfaceIdentity
            )
        }
    }

    @MainActor
    private func finishRuntimeClipboardRead(
        _ text: String,
        requestID: UInt,
        stateAddress: UInt,
        surfaceAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity
    ) {
        guard let terminalSurface,
              surfaceIdentity.matches(terminalSurface),
              surfaceIdentity.surfaceAddress == surfaceAddress,
              let surface = ghostty_surface_t(
                bitPattern: surfaceAddress
              ) else {
            invalidateRuntimeClipboardRequest(
                requestID,
                completingNativeRequest: true,
                deferredInputDisposition: .discard
            )
            return
        }
        guard completeRuntimeClipboardRequest(requestID) else { return }

        // Remote tmux mirror panes need tmux to bracket the paste because the
        // local manual-I/O surface cannot know the remote pane's mode.
        let handledByMirror = !text.isEmpty && (
            AppDelegate.shared?.remoteTmuxController.pasteIntoMirror(
                surfaceId: surfaceId,
                text: text
            ) ?? false
        )
        let completionText = handledByMirror ? "" : text
        completionText.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                UnsafeMutableRawPointer(bitPattern: stateAddress),
                false
            )
        }
        if let surfaceView {
            surfaceView.completeClipboardRead(requestID, confirmed: false) {
                terminalSurface.noteClipboardReadCompleted()
            }
        } else {
            terminalSurface.noteClipboardReadCompleted()
        }
    }

    @MainActor
    func confirmClipboardRead(
        _ text: String,
        stateAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity
    ) {
        surfaceView?.clipboardReadRequiresConfirmation(stateAddress)
        guard let state = UnsafeMutableRawPointer(bitPattern: stateAddress),
              let terminalSurface,
              surfaceIdentity.matches(terminalSurface),
              let surface = terminalSurface.surface,
              UInt(bitPattern: surface) == surfaceIdentity.surfaceAddress else {
            surfaceView?.cancelClipboardRead(
                stateAddress,
                currentEpoch: surfaceView?.terminalSurface?
                    .runtimeSurfaceGeneration ?? .max,
                deferredInputDisposition: .discard
            )
            return
        }
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                state,
                true
            )
        }
        surfaceView?.completeClipboardRead(stateAddress, confirmed: true) {
            terminalSurface.noteClipboardReadCompleted()
        }
    }
}
