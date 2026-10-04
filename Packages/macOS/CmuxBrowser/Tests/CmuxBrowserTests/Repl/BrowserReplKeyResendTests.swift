import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// WebKit sends a key-down no page handled back through `NSApp.sendEvent`
/// (WebViewImpl::doneWithKeyEvent), which routes it to the key window. For a
/// key an agent typed into a tab, that is the user's window: seen live, an
/// agent's `q` in a hidden tab of a background workspace was typed into the
/// user's focused terminal, and an agent's Command key would run cmux menu
/// shortcuts. Automated keys carry a mark, and the app drops a marked key
/// event that reaches it outside the web view's own delivery.
@MainActor
@Suite("Browser REPL unhandled key resend", .serialized)
struct BrowserReplKeyResendTests {
    /// Records the key events WebKit's responder methods receive.
    private final class RecordingWebView: WKWebView {
        var keyDowns: [NSEvent] = []
        override func keyDown(with event: NSEvent) {
            keyDowns.append(event)
        }
        override func keyUp(with event: NSEvent) {}
    }

    private let qKey = SyntheticKeySpecification(
        storedKey: "q",
        keyCode: 12,
        modifierFlags: [],
        characters: "q",
        charactersIgnoringModifiers: "q"
    )

    @Test func keysAWebViewReplaysAreMarkedAsAutomation() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        #expect(webView.replayBrowserKeyboardSpecification(qKey, action: .press, characters: "q") == .delivered)
        let delivered = try #require(webView.keyDowns.first)
        #expect(delivered.isBrowserAutomationKeyEvent)
    }

    @Test func aMarkedKeyOutsideTheWebViewsDeliveryIsAResendToDrop() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        _ = webView.replayBrowserKeyboardSpecification(qKey, action: .keyDown, characters: "q")
        let delivered = try #require(webView.keyDowns.first)
        // WebKit's resend arrives on a later turn, outside any delivery.
        #expect(delivered.isResentBrowserAutomationKeyEvent)
        // The web view's own delivery (arrow keys go through its window) is not a resend.
        webView.withBrowserWebKitKeyDownDispatch {
            #expect(!delivered.isResentBrowserAutomationKeyEvent)
        }
    }

    @Test func theUsersKeysAndShortcutSimulationAreNotAutomation() throws {
        let simulated = try #require(SyntheticKeyEventFactory.keyEvent(specification: qKey, keyDown: true, timestamp: 0, characters: "q"))
        #expect(!simulated.isBrowserAutomationKeyEvent)
        #expect(!simulated.isResentBrowserAutomationKeyEvent)
        let typed = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12
        ))
        #expect(!typed.isBrowserAutomationKeyEvent)
    }
}
