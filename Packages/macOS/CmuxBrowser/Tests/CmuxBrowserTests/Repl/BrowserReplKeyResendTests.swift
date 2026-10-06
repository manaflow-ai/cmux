import AppKit
import ObjectiveC
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

    /// A real web view whose Edit menu actions are counted, not run.
    private final class EditCountingWebView: WKWebView {
        var commands: [String] = []
        override func selectAll(_ sender: Any?) { commands.append("selectAll:") }
        // WebKit's own `copy:` and `paste:`, which Swift does not see.
        @objc(copy:) func countCopy(_ sender: Any?) { commands.append("copy:") }
        @objc(paste:) func countPaste(_ sender: Any?) { commands.append("paste:") }
        @objc(cut:) func countCut(_ sender: Any?) { commands.append("cut:") }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private func load(_ html: String) async throws -> EditCountingWebView {
        _ = NSApplication.shared
        let webView = EditCountingWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
        webView.navigationDelegate = nil
        _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); true")
        return webView
    }

    private func press(_ keys: [String], in webView: WKWebView) throws {
        let events = try keys.map { try #require(BrowserKeyboardEvent(rawKey: $0)) }
        for event in events.dropLast() { #expect(webView.replayBrowserKeyboardEvent(event, action: .keyDown) == .delivered) }
        #expect(webView.replayBrowserKeyboardEvent(events[events.count - 1], action: .press) == .delivered)
        for event in events.dropLast().reversed() { #expect(webView.replayBrowserKeyboardEvent(event, action: .keyUp) == .delivered) }
    }

    /// Waits, at most 30 s, until WebKit has handled every key sent so far
    /// and the page has seen them (`window.keys` counts its keydowns).
    private func settle(_ webView: WKWebView, keys: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if (try await webView.evaluateJavaScript("window.keys || 0") as? Int ?? 0) >= keys { break }
            await Task.yield()
        }
        let pending = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")
        try #require(webView.responds(to: pending))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let block: @convention(block) () -> Void = { continuation.resume() }
            _ = webView.perform(pending, with: block)
        }
        // The command runs on the main actor right after WebKit's callback.
        await Task.yield()
        _ = try await webView.evaluateJavaScript("0")
    }

    /// Runs `body` with `-[NSApplication sendEvent:]` dropping WebKit's
    /// resend of an automated key, as the app's own `sendEvent` does.
    private static func withAppDroppingResends(_ body: () async throws -> Void) async throws {
        _ = NSApplication.shared
        let selector = #selector(NSApplication.sendEvent(_:))
        let method = try #require(class_getInstanceMethod(NSApplication.self, selector))
        let previous = method_getImplementation(method)
        typealias SendEvent = @convention(c) (NSApplication, Selector, NSEvent) -> Void
        let original = unsafeBitCast(previous, to: SendEvent.self)
        let replacement: @convention(block) (NSApplication, NSEvent) -> Void = { app, event in
            let dropped = MainActor.assumeIsolated { event.dropResentBrowserAutomationKeyEvent() }
            if !dropped { original(app, selector, event) }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        defer { method_setImplementation(method, previous) }
        try await body()
    }

    private static let countKeys = "window.keys = 0; addEventListener('keydown', () => { window.keys++; });"

    // WebKit leaves Command+A/C/X/V/Z to the app's Edit menu by sending a key
    // no page handled back to the app, which drops an automated key's resend;
    // so for such a key the web view runs the editing command itself.
    @Test func cmuxBrowserPressRunsAnEditingShortcutNoPageHandled() async throws {
        let webView = try await load("<input id=i value=abc><script>\(Self.countKeys)</script>")
        try press(["Meta", "a"], in: webView)
        try await settle(webView, keys: 2)
        #expect(webView.commands == ["selectAll:"])
        // Without Command, a is just a key.
        try press(["a"], in: webView)
        try await settle(webView, keys: 3)
        #expect(webView.commands == ["selectAll:"])
    }

    // A page that handles the shortcut (it cancels the keydown) does not get
    // the editing command as well, as in a browser: run twice, a Copy or
    // Paste would reach the pasteboard behind the page's back.
    @Test func cmuxBrowserPressDoesNotRunAnEditingShortcutThePageHandled() async throws {
        let webView = try await load(
            "<input id=i value=abc><script>\(Self.countKeys) addEventListener('keydown', e => { if (e.metaKey) e.preventDefault(); });</script>"
        )
        try press(["Meta", "a"], in: webView)
        try press(["Meta", "c"], in: webView)
        try press(["Meta", "v"], in: webView)
        try await settle(webView, keys: 6)
        #expect(webView.commands.isEmpty, "an editing command ran for a shortcut the page handled")
    }

    // `cmux browser press` carries no REPL session: in a tab a session
    // created (one with the page clipboard guard) its Meta+C, Meta+X and
    // Meta+V must reach neither the system pasteboard (the web view's own
    // copy:, cut:, paste:) nor any session's virtual clipboard. A person's
    // Command-C in that tab is not a `cmux browser press` and keeps the
    // web view's own action.
    @Test func cmuxBrowserPressRunsNoClipboardCommandInASessionTab() async throws {
        let webView = try await load("<input id=i value=abc><script>\(Self.countKeys)</script>")
        BrowserReplPageClipboard(shim: try BrowserReplPasteboardTests.PageScripts.shim()).install(on: webView) { _, _ in true }
        try await Self.withAppDroppingResends {
            try press(["Meta", "c"], in: webView)
            try press(["Meta", "x"], in: webView)
            try press(["Meta", "v"], in: webView)
            try press(["Meta", "a"], in: webView)
            try await settle(webView, keys: 8)
        }
        #expect(webView.commands == ["selectAll:"], "cmux browser press ran a clipboard command in a session's tab: \(webView.commands)")
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
        #expect(delivered.dropResentBrowserAutomationKeyEvent())
        // The key's own delivery (arrow keys go through its window) is not a resend.
        webView.withBrowserWebKitKeyDownDispatch(of: delivered) {
            #expect(!delivered.isResentBrowserAutomationKeyEvent)
            #expect(!delivered.dropResentBrowserAutomationKeyEvent())
        }
    }

    /// WebKit's resend of one tab's key can reach the app while another
    /// web view (another tab, another session) delivers its own automated
    /// key. Only that exact key's own delivery exempts it; any other
    /// delivery in flight must not let the resend through to the user's
    /// key window, where it would type into the terminal or run a menu
    /// shortcut.
    @Test func anotherWebViewsDeliveryDoesNotLetAResendThrough() throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let other = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let stroke = try #require(BrowserReplKeyStroke.resolve(key: "q", code: "KeyQ", text: "q", modifiers: []))
        _ = webView.replayBrowserReplKeyStroke(stroke, keyDown: true)
        let delivered = try #require(webView.keyDowns.first)
        other.withBrowserWebKitKeyDownDispatch {
            #expect(delivered.isResentBrowserAutomationKeyEvent,
                    "another web view's delivery hid this key's resend")
            #expect(delivered.dropResentBrowserAutomationKeyEvent())
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
