import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser paste focus message boundary")
struct PasteAsPlainTextFocusMessageHandlerTests {
    @Test("accepts only a boolean canPaste payload")
    func parsesPayloadConservatively() {
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: ["canPaste": true]) == true)
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: ["canPaste": false]) == false)
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: ["canPaste": "true"]) == nil)
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: ["other": true]) == nil)
        #expect(CmuxWebView.pasteAsPlainTextTargetAvailable(from: NSNull()) == nil)
    }
}
