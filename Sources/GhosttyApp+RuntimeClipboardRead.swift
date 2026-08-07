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
        guard let callbackContext = Self.callbackContext(from: userdata) else {
            return false
        }
        let clipboardRequestID = UInt(bitPattern: state)
        let requestSurfaceView = callbackContext.surfaceView
        let operation = TerminalImageTransferOperation()
        guard let requestSurfaceAddress = callbackContext.registerRuntimeClipboardRead(
            id: clipboardRequestID,
            stateAddress: clipboardRequestID,
            operation: operation,
            surfaceView: requestSurfaceView
        ) else {
            return false
        }

        let (startEvents, startContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let preparationTask = Task {
            @MainActor [weak callbackContext, weak requestSurfaceView] in
            var startIterator = startEvents.makeAsyncIterator()
            guard await startIterator.next() != nil,
                  !Task.isCancelled else {
                return
            }
            guard let callbackContext else { return }
            guard let requestSurfaceView,
                  let requestTerminalSurface = callbackContext.terminalSurface,
                  requestTerminalSurface.isActiveRuntimeCallbackContext(
                    callbackContext
                  ),
                  let requestSurfaceIdentity = TerminalClipboardRequestSurfaceIdentity(
                    terminalSurface: requestTerminalSurface
                  ),
                  requestSurfaceIdentity.surfaceAddress == requestSurfaceAddress,
                  let preparationService = requestSurfaceView
                    .imageTransferPreparation else {
                callbackContext.invalidateRuntimeClipboardRequest(
                    clipboardRequestID,
                    completingNativeRequest: true
                )
                return
            }
            guard callbackContext.markRuntimeClipboardRequestAdmitted(
                clipboardRequestID
            ) else {
                return
            }
            var overflowCleanup: () -> Void = {}

            @MainActor
            func completeClipboardRequestOnMain(with text: String) {
                callbackContext.completeRuntimeClipboardRead(
                    text,
                    requestID: clipboardRequestID,
                    stateAddress: clipboardRequestID,
                    surfaceAddress: requestSurfaceAddress,
                    surfaceIdentity: requestSurfaceIdentity
                )
            }

            func completeClipboardRequest(with text: String) {
                Task { @MainActor [weak callbackContext] in
                    callbackContext?.completeRuntimeClipboardRead(
                        text,
                        requestID: clipboardRequestID,
                        stateAddress: clipboardRequestID,
                        surfaceAddress: requestSurfaceAddress,
                        surfaceIdentity: requestSurfaceIdentity
                    )
                }
            }

            requestSurfaceView.beginReservedClipboardRead(
                clipboardRequestID,
                epoch: requestSurfaceIdentity.generation,
                onOverflow: {
                    _ = operation.cancel()
                    overflowCleanup()
                    completeClipboardRequestOnMain(with: "")
                }
            )

            guard let pasteboard = terminalPasteboard.pasteboard(for: location) else {
                completeClipboardRequest(with: "")
                return
            }
            let pasteboardTypeDescription = (pasteboard.types ?? [])
                .map(\.rawValue)
                .joined(separator: ",")

            let preparedContent = await TerminalImageTransferPlanner.prepare(
                pasteboard: pasteboard,
                mode: .paste,
                using: preparationService
            )

            guard !operation.isCancelled else {
                if case .fileURLs(let fileURLs) = preparedContent {
                    terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                }
                return
            }

            guard requestSurfaceIdentity.matches(requestTerminalSurface) else {
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
                let indicatorView = requestTerminalSurface.hostedView
                indicatorView.beginImageTransferIndicator(
                    for: operation,
                    onCancel: {
                        completeClipboardRequest(with: "")
                    }
                )
                overflowCleanup = {
                    indicatorView.endImageTransferIndicator(for: operation)
                }

                let target = requestTerminalSurface
                    .resolvedImageTransferTarget()
                let plan = TerminalImageTransferPlanner.plan(
                    fileURLs: fileURLs,
                    target: target
                )

                let handledByCustomUpload = Self.handleCustomPasteUploadIfMatched(
                    plan: plan,
                    operation: operation,
                    callbackContext: callbackContext,
                    surfaceIdentity: requestSurfaceIdentity,
                    indicatorView: indicatorView,
                    completeClipboardRequest: completeClipboardRequest
                )

                if !handledByCustomUpload {
                    TerminalImageTransferPlanner.execute(
                        plan: plan,
                        operation: operation,
                        uploadWorkspaceRemote: { fileURLs, operation, finish in
                            let workspace: Workspace? = MainActor.assumeIsolated {
                                guard requestSurfaceIdentity.matches(
                                    requestTerminalSurface
                                ) else { return nil }
                                return requestTerminalSurface.owningWorkspace()
                            }
                            guard let workspace else {
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
                                requestSurfaceIdentity.matches(requestTerminalSurface)
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
                                indicatorView.endImageTransferIndicator(
                                    for: operation
                                )
                            }
                            completeClipboardRequest(with: text)
                        },
                        onFailure: { _ in
                            let shouldPresentFailure = MainActor.assumeIsolated {
                                indicatorView.endImageTransferIndicator(
                                    for: operation
                                )
                                return requestSurfaceIdentity.matches(
                                    requestTerminalSurface
                                )
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
        let attached = callbackContext.attachRuntimeClipboardTask(
            preparationTask,
            requestID: clipboardRequestID
        )
        let committed = attached && callbackContext
            .commitRuntimeClipboardRequest(clipboardRequestID)
        if committed {
            startContinuation.yield()
        } else {
            preparationTask.cancel()
        }
        startContinuation.finish()

        return committed
    }
}
