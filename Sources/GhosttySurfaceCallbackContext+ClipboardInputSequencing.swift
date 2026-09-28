import AppKit
import CmuxSettings
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
        readContent: RuntimeClipboardReadContent,
        requestID: UInt,
        stateAddress: UInt,
        surfaceAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity
    ) {
        guard let surfaceView else {
            finishRuntimeClipboardRead(
                text,
                readContent: readContent,
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
                readContent: readContent,
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
        readContent: RuntimeClipboardReadContent,
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
        // local manual-I/O surface cannot know the remote pane's mode. A read
        // the terminal program started answers that program instead, so it
        // never becomes input to the remote pane.
        let handledByMirror = readContent == .pasteboard && !text.isEmpty && (
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
        isPasteRequest: Bool,
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
        let window = surfaceView?.window
        let policy = TerminalUnsafePasteConfirmationPolicy(
            confirmationEnabled: TerminalCatalogSection().confirmUnsafePaste
                .value(in: .standard)
        )
        switch policy.decision(
            isPasteRequest: isPasteRequest,
            hasWindow: window != nil
        ) {
        case .approve:
            break
        case .askInWindowSheet:
            if let window,
               askToConfirmClipboardRequest(
                   text,
                   isPasteRequest: isPasteRequest,
                   preview: policy.preview(of: text),
                   stateAddress: stateAddress,
                   surfaceIdentity: surfaceIdentity,
                   window: window
               ) {
                return
            }
            // The request could not be tracked while the sheet is open, so
            // there is no safe way to ask. Do not paste or share unasked.
            NSSound.beep()
            finishConfirmedClipboardRead("", state: state, surface: surface)
            return
        case .reject:
            NSSound.beep()
            finishConfirmedClipboardRead("", state: state, surface: surface)
            return
        }
        finishConfirmedClipboardRead(text, state: state, surface: surface)
    }

    /// Completes a request Ghostty held for confirmation. Empty text
    /// completes it without pasting and still releases libghostty's request.
    @MainActor
    private func finishConfirmedClipboardRead(
        _ text: String,
        state: UnsafeMutableRawPointer,
        surface: ghostty_surface_t
    ) {
        let stateAddress = UInt(bitPattern: state)
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                state,
                true
            )
        }
        let terminalSurface = terminalSurface
        surfaceView?.completeClipboardRead(stateAddress, confirmed: true) {
            terminalSurface?.noteClipboardReadCompleted()
        }
    }

    /// Shows a sheet on `window` asking whether to complete the request, and
    /// answers Ghostty when the user chooses: the `terminal.confirmUnsafePaste`
    /// sheet for a paste, or a clipboard access sheet for a read the terminal
    /// program started.
    ///
    /// The native request is registered again for the sheet's lifetime, so
    /// runtime teardown completes it and closes the sheet instead of leaving
    /// a request that points at a freed surface.
    ///
    /// - Returns: Whether the sheet was shown and now owns the request.
    @MainActor
    private func askToConfirmClipboardRequest(
        _ text: String,
        isPasteRequest: Bool,
        preview: String,
        stateAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity,
        window: NSWindow
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let explanation: String
        if isPasteRequest {
            alert.messageText = String(
                localized: "terminal.unsafePasteConfirmation.title",
                defaultValue: "Paste Potentially Unsafe Text?"
            )
            explanation = String(
                localized: "terminal.unsafePasteConfirmation.message",
                defaultValue: "This text could run commands as soon as it is pasted, for example because it contains a line break. Paste it only if you trust it."
            )
            alert.addButton(withTitle: String(
                localized: "terminal.unsafePasteConfirmation.paste",
                defaultValue: "Paste"
            ))
            alert.addButton(withTitle: String(
                localized: "common.cancel",
                defaultValue: "Cancel"
            ))
        } else {
            alert.messageText = String(
                localized: "terminal.clipboardReadConfirmation.title",
                defaultValue: "Allow Clipboard Access?"
            )
            explanation = String(
                localized: "terminal.clipboardReadConfirmation.message",
                defaultValue: "A program in this terminal wants to read your clipboard. Allow it only if you trust the program."
            )
            alert.addButton(withTitle: String(
                localized: "common.allow",
                defaultValue: "Allow"
            ))
            alert.addButton(withTitle: String(
                localized: "terminal.clipboardReadConfirmation.deny",
                defaultValue: "Deny"
            ))
        }
        alert.informativeText = preview.isEmpty
            ? explanation
            : explanation + "\n\n" + preview

        let surfaceAddress = surfaceIdentity.surfaceAddress
        let requestSurfaceView = surfaceView
        guard registerRuntimeClipboardRequest(
            id: stateAddress,
            onInvalidation: {
                @MainActor [weak alert, weak requestSurfaceView]
                _,
                completesNativeRequest,
                _,
                deferredInputDisposition in
                if let sheet = alert?.window, let parent = sheet.sheetParent {
                    parent.endSheet(sheet, returnCode: .abort)
                }
                if completesNativeRequest,
                   let surface = ghostty_surface_t(bitPattern: surfaceAddress) {
                    // Teardown cannot wait for an answer; approving empty
                    // text makes libghostty release its request.
                    "".withCString { pointer in
                        ghostty_surface_complete_clipboard_request(
                            surface,
                            pointer,
                            UnsafeMutableRawPointer(bitPattern: stateAddress),
                            true
                        )
                    }
                }
                requestSurfaceView?.cancelClipboardRead(
                    stateAddress,
                    currentEpoch: requestSurfaceView?.terminalSurface?
                        .runtimeSurfaceGeneration ?? .max,
                    deferredInputDisposition: deferredInputDisposition
                )
            }
        ) else {
            return false
        }
        guard commitRuntimeClipboardRequest(stateAddress) else {
            invalidateRuntimeClipboardRequest(
                stateAddress,
                completingNativeRequest: false,
                deferredInputDisposition: .replay
            )
            return false
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.answerUnsafePasteConfirmation(
                    approved: response == .alertFirstButtonReturn,
                    text: text,
                    stateAddress: stateAddress,
                    surfaceIdentity: surfaceIdentity
                )
            }
        }
        return true
    }

    @MainActor
    private func answerUnsafePasteConfirmation(
        approved: Bool,
        text: String,
        stateAddress: UInt,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity
    ) {
        // Teardown may already have completed the request and closed the
        // sheet; only the first completion may answer libghostty.
        guard completeRuntimeClipboardRequest(stateAddress) else { return }
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
        finishConfirmedClipboardRead(
            approved ? text : "",
            state: state,
            surface: surface
        )
    }
}
