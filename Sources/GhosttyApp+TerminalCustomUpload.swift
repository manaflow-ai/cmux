import AppKit
import CmuxTerminalCore

extension GhosttyApp {
    @discardableResult
    static func handleCustomPasteUploadIfMatched(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation,
        callbackContext: GhosttySurfaceCallbackContext,
        surfaceIdentity: TerminalClipboardRequestSurfaceIdentity,
        completeClipboardRequest: @escaping (String) -> Void
    ) -> Bool {
        TerminalCustomUploadRunner().handleIfMatched(
            plan: plan,
            operation: operation,
            cleanup: { terminalPasteboard.cleanupTransferredTemporaryImageFiles($0) },
            completion: { result in
                let shouldDeliverResult = MainActor.assumeIsolated {
                    guard surfaceIdentity.matches(callbackContext.terminalSurface) else { return false }
                    callbackContext.terminalSurface?.hostedView
                        .endImageTransferIndicator(for: operation)
                    return true
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
