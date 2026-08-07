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
                guard shouldDeliverResult else {
                    completeClipboardRequest("")
                    return
                }
                switch result {
                case .success(let text):
                    completeClipboardRequest(text)
                case .failure:
                    NSSound.beep()
#if DEBUG
                    cmuxDebugLog("terminal.remotePasteUpload.customFailed surface=\(callbackContext.surfaceId.uuidString.prefix(5))")
#endif
                    completeClipboardRequest("")
                }
            }
        )
    }
}
