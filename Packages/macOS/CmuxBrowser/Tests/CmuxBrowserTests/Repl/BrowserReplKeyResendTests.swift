import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// WebKit sends a key-down no page handled back through `NSApp.sendEvent`
/// (WebViewImpl::doneWithKeyEvent), which routes it to the key window. For a
/// key an agent typed into a tab, that is the user's window: seen live, an
/// agent's `q` in a hidden tab of a background workspace was typed into the
/// user's focused terminal, and an agent's Command key would run cmux menu
/// shortcuts. Keys the REPL and `cmux browser press` send carry a mark, and
/// the app drops a marked key event that reaches it outside the web view's
/// own delivery. The mobile browser stream's keys (a person on a phone) keep
/// the resend.
@MainActor
@Suite("Browser REPL unhandled key resend", .serialized)
struct BrowserReplKeyResendTests {
    /// Records the key events WebKit's responder methods receive.
    private final class RecordingWebView: WKWebView {
        var keyDowns: [NSEvent] = []
        var selectAllCount = 0
        override func selectAll(_ sender: Any?) {
            selectAllCount += 1
        }
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

    @Test func keysTheReplTypesAreMarkedAsAutomation() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let stroke = try #require(BrowserReplKeyStroke.resolve(key: "q", code: "KeyQ", text: "q", modifiers: []))
        #expect(webView.replayBrowserReplKeyStroke(stroke, keyDown: true) == .delivered)
        let delivered = try #require(webView.keyDowns.first)
        #expect(delivered.isBrowserAutomationKeyEvent)
    }

    @Test func keysCmuxBrowserPressSendsAreMarkedAsAutomation() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let event = try #require(BrowserKeyboardEvent(rawKey: "q"))
        #expect(webView.replayBrowserKeyboardEvent(event, action: .press) == .delivered)
        let delivered = try #require(webView.keyDowns.first)
        #expect(delivered.isBrowserAutomationKeyEvent)
    }

    // cmux browser press Meta+a selected all through WebKit's resend to the
    // Edit menu; with the resend dropped, the web view runs the editing
    // command itself, as the REPL does.
    @Test func cmuxBrowserPressRunsEditingShortcutsOnTheWebView() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let meta = try #require(BrowserKeyboardEvent(rawKey: "Meta"))
        let a = try #require(BrowserKeyboardEvent(rawKey: "a"))
        #expect(webView.replayBrowserKeyboardEvent(meta, action: .keyDown) == .delivered)
        #expect(webView.replayBrowserKeyboardEvent(a, action: .press) == .delivered)
        #expect(webView.replayBrowserKeyboardEvent(meta, action: .keyUp) == .delivered)
        #expect(webView.selectAllCount == 1)
        // Without Command, a is just a key.
        #expect(webView.replayBrowserKeyboardEvent(a, action: .press) == .delivered)
        #expect(webView.selectAllCount == 1)
    }

    // The mobile browser stream replays a person's keys from their phone
    // through the specification entry point; WebKit's resend of a key no page
    // handled keeps reaching the Mac's menus there, as before.
    @Test func keysTheMobileStreamReplaysKeepWebKitsResend() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        #expect(webView.replayBrowserKeyboardSpecification(qKey, action: .press, characters: "q") == .delivered)
        let delivered = try #require(webView.keyDowns.first)
        #expect(!delivered.isBrowserAutomationKeyEvent)
        #expect(!delivered.isResentBrowserAutomationKeyEvent)
    }

    @Test func aMarkedKeyOutsideTheWebViewsDeliveryIsAResendToDrop() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let stroke = try #require(BrowserReplKeyStroke.resolve(key: "q", code: "KeyQ", text: "q", modifiers: []))
        _ = webView.replayBrowserReplKeyStroke(stroke, keyDown: true)
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
