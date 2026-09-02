import AppKit
import CmuxTerminalCore

extension GhosttyApp {
    @discardableResult
    static func handleCustomPasteUploadIfMatched(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation,
        callbackContext: GhosttySurfaceCallbackContext,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity,
        indicatorView: GhosttySurfaceScrollView,
        completeClipboardRequest: @escaping (String) -> Void
    ) -> Bool {
        TerminalCustomUploadRunner().handleIfMatched(
            plan: plan,
            operation: operation,
            cleanup: { terminalPasteboard.cleanupTransferredTemporaryImageFiles($0) },
            completion: { result in
                let shouldDeliverResult = MainActor.assumeIsolated {
                    indicatorView.endImageTransferIndicator(for: operation)
                    return surfaceIdentity.matches(callbackContext.terminalSurface)
                }
                // Report a failure whether or not the surface is still the one
                // the paste started on: the notification has its own fallback
                // (the focused workspace) for a surface that has gone away, and
                // the identity guard below only decides where TEXT may go.
                if case .failure(let error) = result {
                    // surfaceId came from the callback context captured when the
                    // paste started, so it names the surface the user dropped on.
                    let outcome = MainActor.assumeIsolated {
                        TerminalUploadFailureNotification.post(
                            error: error,
                            surfaceId: callbackContext.surfaceId
                        )
                    }
                    if outcome == .unavailable { NSSound.beep() }
#if DEBUG
                    cmuxDebugLog("terminal.remotePasteUpload.customFailed surface=\(callbackContext.surfaceId.uuidString.prefix(5))")
#endif
                }
                guard shouldDeliverResult else {
                    completeClipboardRequest("")
                    return
                }
                switch result {
                case .success(let text):
                    completeClipboardRequest(text)
                case .failure:
                    completeClipboardRequest("")
                }
            }
        )
    }
}
