import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// WebKit hands a key command no page handled (Escape's `cancel:`) to the
/// web view's superclass, and from there it goes up the responder chain to
/// the window. For Escape the window runs its cancel key: every view is
/// offered the key as a key equivalent and the first responder gets
/// `cancel:`. Seen live: `cmux browser press Escape` on a tab next to the
/// user's terminal interrupted the agent running in that terminal.
/// https://github.com/manaflow-ai/cmux/issues/41921
@MainActor
@Suite("Browser automation unhandled key commands", .serialized)
struct BrowserAutomationUnhandledCommandTests {
    /// Stands in for the user's terminal.
    private final class Terminal: NSView {
        var commands: [String] = []
        var keyEquivalents: [UInt16] = []
        override var acceptsFirstResponder: Bool { true }
        override func doCommand(by selector: Selector) { commands.append(NSStringFromSelector(selector)) }
        override func cancelOperation(_ sender: Any?) { commands.append("cancelOperation:") }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            keyEquivalents.append(event.keyCode)
            return false
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private struct Setup {
        let window: NSWindow
        let webView: CmuxUndoableWebView
        let terminal: Terminal
    }

    /// A page that counts its keydowns, in a window next to a terminal.
    private func makeWindow() async -> Setup {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let webView = CmuxUndoableWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let terminal = Terminal(frame: NSRect(x: 300, y: 0, width: 100, height: 300))
        content.addSubview(webView)
        content.addSubview(terminal)
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.continuation = continuation
            webView.loadHTMLString(
                "<body><script>window.keys = 0; addEventListener('keydown', () => { window.keys++; });</script>",
                baseURL: URL(string: "https://example.com/")
            )
        }
        webView.navigationDelegate = nil
        // The page leaves the command to the app only while its window is on
        // screen. A transparent window behind the others is enough.
        window.alphaValue = 0
        window.orderBack(nil)
        return Setup(window: window, webView: webView, terminal: terminal)
    }

    /// Presses Escape as `cmux browser press Escape` does and waits until
    /// the page is done with it. The page handles a key and then asks the
    /// app, in a synchronous message, to run the command it left unhandled,
    /// before it answers anything else. So once the page has counted the
    /// keydown, the answer to one more script arrives after that command.
    private func pressEscape(in webView: WKWebView) async throws {
        let escape = try #require(BrowserKeyboardEvent(rawKey: "Escape"))
        #expect(await webView.replayBrowserKeyboardEvent(escape, action: .press) == .delivered)
        try await settle(webView, keys: 1)
    }

    private func settle(_ webView: WKWebView, keys: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var counted = 0
        while ContinuousClock.now < deadline, counted < keys {
            counted = try await webView.evaluateJavaScript("window.keys") as? Int ?? 0
        }
        try #require(counted == keys, "the page received \(counted) of \(keys) keys")
        _ = try await webView.evaluateJavaScript("0")
    }

    @Test func escapeSentToAPageDoesNotReachTheUsersTerminal() async throws {
        let setup = await makeWindow()
        defer { setup.window.close() }
        #expect(setup.window.makeFirstResponder(setup.terminal))
        try await pressEscape(in: setup.webView)
        #expect(setup.terminal.commands == [])
        #expect(setup.terminal.keyEquivalents == [])
        #expect(setup.window.firstResponder === setup.terminal)
    }

    // A person's Escape in a page they are typing in still reaches the
    // window, which is how Escape closes a sheet or leaves full screen.
    @Test func escapeInTheFocusedWebViewStillReachesTheWindow() async throws {
        let setup = await makeWindow()
        defer { setup.window.close() }
        #expect(setup.window.makeFirstResponder(setup.webView))
        try await pressEscape(in: setup.webView)
        #expect(setup.terminal.keyEquivalents == [53])
    }
}
