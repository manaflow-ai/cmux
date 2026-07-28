import AppKit
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit

extension GhosttyApp {
    static func runtimeReadClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let callbackContext = Self.callbackContext(from: userdata),
              let terminalSurface = callbackContext.terminalSurface,
              let requestSurface = terminalSurface.surface else { return false }
        let requestSurfaceIdentity = TerminalClipboardRequestSurfaceIdentity(
            surfaceAddress: UInt(bitPattern: requestSurface),
            generation: terminalSurface.runtimeSurfaceGeneration
        )
        let clipboardRequestID = UInt(bitPattern: state)
        let requestSurfaceView = callbackContext.surfaceView
        requestSurfaceView?.reserveClipboardReadAdmission()

        Task { @MainActor [weak requestSurfaceView] in
            requestSurfaceView?.beginReservedClipboardRead(clipboardRequestID)
            func completeClipboardRequest(with text: String) {
                Task { @MainActor in
                    defer {
                        requestSurfaceView?.completeClipboardRead(
                            clipboardRequestID,
                            confirmed: false
                        )
                    }
                    guard requestSurfaceIdentity.matches(callbackContext.terminalSurface) else { return }
                    // Remote tmux mirror panes need tmux to bracket the paste
                    // because the local manual-I/O surface cannot know the
                    // remote pane's bracketed-paste mode.
                    let handledByMirror = !text.isEmpty && (
                        AppDelegate.shared?.remoteTmuxController.pasteIntoMirror(
                            surfaceId: callbackContext.surfaceId,
                            text: text
                        ) ?? false
                    )
                    let completionText = handledByMirror ? "" : text
                    completionText.withCString { pointer in
                        ghostty_surface_complete_clipboard_request(
                            requestSurface,
                            pointer,
                            state,
                            false
                        )
                    }
                    callbackContext.terminalSurface?.noteClipboardReadCompleted()
                }
            }

            guard let pasteboard = terminalPasteboard.pasteboard(for: location) else {
                completeClipboardRequest(with: "")
                return
            }
            let pasteboardTypeDescription = (pasteboard.types ?? [])
                .map(\.rawValue)
                .joined(separator: ",")

            let preparedContent = await TerminalImageTransferPlanner.prepare(
                pasteboard: pasteboard,
                mode: .paste
            )

            guard requestSurfaceIdentity.matches(callbackContext.terminalSurface) else {
                if case .fileURLs(let fileURLs) = preparedContent {
                    terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                }
                completeClipboardRequest(with: "")
                return
            }

#if DEBUG
            cmuxDebugLog(
                "terminal.clipboard.read surface=\(callbackContext.surfaceId.uuidString.prefix(5)) " +
                "types=\(pasteboardTypeDescription) " +
                "prepared=\(preparedContent.cmuxDebugDescription)"
            )
#endif

            switch preparedContent {
            case .reject:
                completeClipboardRequest(with: "")
            case .insertText(let text):
                completeClipboardRequest(with: text)
            case .fileURLs(let fileURLs):
                let operation = TerminalImageTransferOperation()
                callbackContext.terminalSurface?.hostedView.beginImageTransferIndicator(
                    for: operation,
                    onCancel: {
                        completeClipboardRequest(with: "")
                    }
                )

                let target = callbackContext.terminalSurface?
                    .resolvedImageTransferTarget() ?? .local
                let plan = TerminalImageTransferPlanner.plan(
                    fileURLs: fileURLs,
                    target: target
                )

                let handledByCustomUpload = Self.handleCustomPasteUploadIfMatched(
                    plan: plan,
                    operation: operation,
                    callbackContext: callbackContext,
                    surfaceIdentity: requestSurfaceIdentity,
                    completeClipboardRequest: completeClipboardRequest
                )

                if !handledByCustomUpload {
                    TerminalImageTransferPlanner.execute(
                        plan: plan,
                        operation: operation,
                        uploadWorkspaceRemote: { fileURLs, operation, finish in
                            guard let workspace = MainActor.assumeIsolated({
                                guard requestSurfaceIdentity.matches(
                                    callbackContext.terminalSurface
                                ) else { return nil }
                                return callbackContext.terminalSurface?.owningWorkspace()
                            }) else {
                                finish(.failure(NSError(domain: "cmux.remote.paste", code: 3)))
                                terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                                return
                            }
                            workspace.uploadDroppedFilesForRemoteTerminal(
                                fileURLs,
                                operation: operation,
                                completion: { result in
                                    finish(result)
                                    terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                                }
                            )
                        },
                        uploadDetectedSSH: { session, fileURLs, operation, finish in
                            guard MainActor.assumeIsolated({
                                requestSurfaceIdentity.matches(callbackContext.terminalSurface)
                            }) else {
                                finish(.failure(NSError(domain: "cmux.remote.paste", code: 4)))
                                terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                                return
                            }
                            session.uploadDroppedFiles(
                                fileURLs,
                                operation: operation,
                                completion: { result in
                                    finish(result)
                                    terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                                }
                            )
                        },
                        insertText: { text in
                            MainActor.assumeIsolated {
                                guard requestSurfaceIdentity.matches(
                                    callbackContext.terminalSurface
                                ) else { return }
                                callbackContext.terminalSurface?.hostedView.endImageTransferIndicator(
                                    for: operation
                                )
                            }
                            completeClipboardRequest(with: text)
                        },
                        onFailure: { _ in
                            let shouldPresentFailure = MainActor.assumeIsolated {
                                guard requestSurfaceIdentity.matches(
                                    callbackContext.terminalSurface
                                ) else { return false }
                                callbackContext.terminalSurface?.hostedView.endImageTransferIndicator(
                                    for: operation
                                )
                                return true
                            }
                            if shouldPresentFailure {
                                NSSound.beep()
#if DEBUG
                                cmuxDebugLog(
                                    "terminal.remotePasteUpload.failed " +
                                    "surface=\(callbackContext.surfaceId.uuidString.prefix(5))"
                                )
#endif
                            }
                            completeClipboardRequest(with: "")
                        }
                    )
                }
            }
        }

        return true
    }
}
