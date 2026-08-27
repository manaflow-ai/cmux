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
        TerminalCustomUploadRunner().handleIfMatched(
            plan: plan,
            operation: operation,
            cleanup: { GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles($0) },
            completion: { [weak self] result in
                self?.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
                switch result {
                case .success(let text):
                    self?.deliverUploadResultText(text)
                case .failure:
                    NSSound.beep()
#if DEBUG
                    cmuxDebugLog("terminal.remoteDropUpload.customFailed surface=\(self?.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                }
            }
        )
    }
}
