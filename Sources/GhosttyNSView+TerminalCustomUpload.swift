import AppKit

extension GhosttyNSView {
    @discardableResult
    func deliverUploadResultText(
        _ text: String,
        onCompleted: @escaping () -> Void = {}
    ) -> Bool {
        guard let surface = terminalSurface else {
            onCompleted()
            return false
        }
        let surfaceID = surface.id
        let handledByMirror = MainActor.assumeIsolated {
            AppDelegate.shared?.remoteTmuxController.pasteIntoMirror(
                surfaceId: surface.id,
                text: text
            ) ?? false
        }
        if handledByMirror {
            onCompleted()
            return true
        }

        // Keep owned temporary image files alive while a runtime clipboard
        // read is still holding input. The replay closure invokes the same
        // completion only after the text has reached the terminal.
        if deferRuntimeInputDuringClipboardRead(
            estimatedBytes: text.utf8.count,
            replay: { [weak self] in
                guard let self,
                      self.terminalSurface?.id == surfaceID else {
                    onCompleted()
                    return
                }
                _ = self.deliverUploadResultText(
                    text,
                    onCompleted: onCompleted
                )
            }
        ) {
            return true
        }

        let accepted = surface.sendText(text)
        onCompleted()
        return accepted
    }

    @discardableResult
    func handleCustomDropUploadIfMatched(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation
    ) -> Bool {
        // Captured before the upload starts: this view can be reattached to a
        // different surface while it runs, so reading it back in the completion
        // would name whichever surface happens to be mounted then.
        let originSurfaceId = terminalSurface?.id
        // The indicator was started on this view; end it on the same one even
        // if a different surface is mounted by the time the upload finishes.
        weak var originHostedView = terminalSurface?.hostedView
        return TerminalCustomUploadRunner().handleIfMatched(
            plan: plan,
            operation: operation,
            cleanup: { GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles($0) },
            completion: { [weak self] result in
                (originHostedView ?? self?.terminalSurface?.hostedView)?.endImageTransferIndicator(for: operation)
                switch result {
                case .success(let text):
                    self?.deliverUploadResultText(text)
                case .failure(let error):
                    // The runner delivers this on the main queue; state the proof the
                    // same way the sibling call sites do.
                    let outcome = MainActor.assumeIsolated {
                        TerminalUploadFailureNotification.post(
                            error: error,
                            surfaceId: originSurfaceId
                        )
                    }
                    if outcome == .unavailable { NSSound.beep() }
#if DEBUG
                    cmuxDebugLog("terminal.remoteDropUpload.customFailed surface=\(originSurfaceId?.uuidString.prefix(5) ?? "nil")")
#endif
                }
            }
        )
    }
}
