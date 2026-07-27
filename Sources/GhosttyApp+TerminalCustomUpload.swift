import AppKit
import CmuxTerminalCore

extension GhosttyApp {
    @discardableResult
    static func handleCustomPasteUploadIfMatched(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation,
        callbackContext: GhosttySurfaceCallbackContext,
        completeClipboardRequest: @escaping (String) -> Void
    ) -> Bool {
        TerminalCustomUploadRunner().handleIfMatched(
            plan: plan,
            operation: operation,
            cleanup: { terminalPasteboard.cleanupTransferredTemporaryImageFiles($0) },
            completion: { result in
                MainActor.assumeIsolated {
                    callbackContext.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
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
