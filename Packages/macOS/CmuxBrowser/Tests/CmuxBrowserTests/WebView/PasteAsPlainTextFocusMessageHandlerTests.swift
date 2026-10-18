import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser paste focus message boundary")
struct PasteAsPlainTextFocusMessageHandlerTests {
    /// The parser rejects values that cannot safely drive the paste state.
    @Test("accepts only a boolean canPaste payload")
    func parsesPayloadConservatively() {
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: ["canPaste": true]) == true)
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: ["canPaste": false]) == false)
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: ["canPaste": "true"]) == nil)
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: ["other": true]) == nil)
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: NSNull()) == nil)
    }

    /// The callback boundary delivers valid payloads through MainActor.
    @Test("schedules valid payload updates on MainActor")
    func schedulesPayloadUpdate() async {
        let delivered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            CmuxWebView.schedulePasteAsPlainTextTargetUpdate(from: ["canPaste": true]) { canPaste in
                continuation.resume(returning: canPaste)
            }
        }

        #expect(delivered)
    }
}
