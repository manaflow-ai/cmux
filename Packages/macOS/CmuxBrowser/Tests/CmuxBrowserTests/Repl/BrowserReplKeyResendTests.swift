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
    /// Whether this WebKit reports if a page handled a key
    /// (`_doAfterProcessingAllPendingKeyEvents:`; macOS 26's WebKit lacks
    /// it). Without it Edit shortcuts are refused before their key leaves
    /// (BrowserReplOlderWebKitTests), so the tests of what such a shortcut
    /// does run only where WebKit can report it.
    nonisolated static var webKitReportsKeyOutcome: Bool {
        WKWebView.instancesRespond(to: NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:"))
    }

    nonisolated static let needsKeyOutcome = "needs WebKit's _doAfterProcessingAllPendingKeyEvents:, which this WebKit lacks (macOS 26); BrowserReplOlderWebKitTests covers the refusal there"

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
        let stroke = try #require(try BrowserReplKeyStroke.resolve(key: "q", code: "KeyQ", text: "q", modifiers: []))
        #expect(webView.replayBrowserReplKeyStroke(stroke, keyDown: true) == .delivered)
        let delivered = try #require(webView.keyDowns.first)
        #expect(delivered.isBrowserAutomationKeyEvent)
    }

    @Test func keysCmuxBrowserPressSendsAreMarkedAsAutomation() async throws {
        let webView = RecordingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let event = try #require(BrowserKeyboardEvent(rawKey: "q"))
        #expect(await webView.replayBrowserKeyboardEvent(event, action: .press) == .delivered)
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

    /// Presses `keys` as `cmux browser press` does, one socket call per key.
    private func press(_ keys: [String], in webView: WKWebView) async throws {
        let events = try keys.map { try #require(BrowserKeyboardEvent(rawKey: $0)) }
        for event in events.dropLast() { #expect(await webView.replayBrowserKeyboardEvent(event, action: .keyDown) == .delivered) }
        #expect(await webView.replayBrowserKeyboardEvent(events[events.count - 1], action: .press) == .delivered)
        for event in events.dropLast().reversed() { #expect(await webView.replayBrowserKeyboardEvent(event, action: .keyUp) == .delivered) }
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
    ///
    /// A test that expects an editing command to run needs it: the drop is
    /// how the app learns a key was unhandled (`noteResent`). Without it the
    /// outcome falls back to whether `NSApp.currentEvent` is still the key
    /// when WebKit's callback runs, and the real `sendEvent` (key-equivalent
    /// and Services matching) and other suites running on the main actor in
    /// the same process can change that process-wide state first, so the
    /// command was skipped on loaded or differently set up machines (CI).
    static func withAppDroppingResends(_ body: () async throws -> Void) async throws {
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
    @Test(.enabled(if: BrowserReplKeyResendTests.webKitReportsKeyOutcome, Comment(rawValue: BrowserReplKeyResendTests.needsKeyOutcome)))
    func cmuxBrowserPressRunsAnEditingShortcutNoPageHandled() async throws {
        let webView = try await load("<input id=i value=abc><script>\(Self.countKeys)</script>")
        try await Self.withAppDroppingResends {
            try await press(["Meta", "a"], in: webView)
            try await settle(webView, keys: 2)
            #expect(webView.commands == ["selectAll:"])
            // Without Command, a is just a key.
            try await press(["a"], in: webView)
            try await settle(webView, keys: 3)
            #expect(webView.commands == ["selectAll:"])
        }
    }

    /// A web view in a window, the first responder there, with the page's
    /// field focused: as in the app, WebKit gives a key in editable content
    /// to the window's input method first, and only then queues it for the
    /// page. A web view outside a window has no input context and queues
    /// the key at once, so tests without a window never see that stage.
    private func loadInWindow(_ html: String) async throws -> (NSWindow, EditCountingWebView) {
        let webView = try await load(html)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        #expect(window.makeFirstResponder(webView))
        _ = try await webView.evaluateJavaScript("document.getElementById('i').focus(); true")
        // WebKit reports the editable focus to the UI process asynchronously.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline, webView.inputContext == nil {
            _ = try await webView.evaluateJavaScript("0")
        }
        try #require(webView.inputContext != nil, "the focused field never gave the web view an input context")
        return (window, webView)
    }

    /// A slow input method for one web view. In editable content of a web
    /// view in a window, WebKit gives each key to the window's input method
    /// first and queues it for the page when the input method answers, in
    /// order. Here the answer for a Command key-down comes only once every
    /// key WebKit queued before it has been handled, and on a later turn;
    /// the keys after it wait behind it. In the app that answer races the
    /// page's handling of the earlier key; this makes the losing order
    /// certain.
    @MainActor
    private final class SlowInputMethod {
        private struct Answer {
            let event: NSEvent
            let deliver: () -> Void
            var waitsForQueue: Bool
        }

        private weak var webView: WKWebView?
        private var answers: [Answer] = []
        private var waiting = false
        /// The keys WebKit has been given back, in order.
        private(set) var answered: [NSEvent] = []
        private var answerWaiters: [CheckedContinuation<Void, Never>] = []

        /// Returns once WebKit has been given back at least `count` keys.
        func waitForAnswers(_ count: Int) async {
            while answered.count < count {
                await withCheckedContinuation { answerWaiters.append($0) }
            }
        }

        init(webView: WKWebView) { self.webView = webView }

        func answer(_ event: NSEvent, _ deliver: @escaping () -> Void) {
            answers.append(Answer(event: event, deliver: deliver, waitsForQueue: event.type == .keyDown && event.modifierFlags.contains(.command)))
            pump()
        }

        private func pump() {
            while let first = answers.first {
                if first.waitsForQueue {
                    guard !waiting else { return }
                    waiting = true
                    let release: @convention(block) () -> Void = { [weak self] in
                        RunLoop.main.perform {
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                self.waiting = false
                                self.answers[0].waitsForQueue = false
                                self.pump()
                            }
                        }
                    }
                    let pending = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")
                    if let webView, webView.responds(to: pending) { _ = webView.perform(pending, with: release) } else { release() }
                    return
                }
                answers.removeFirst()
                answered.append(first.event)
                first.deliver()
                let waiters = answerWaiters
                answerWaiters = []
                waiters.forEach { $0.resume() }
            }
        }

        /// Runs `body` with this input method answering for every text input context.
        func install(_ body: () async throws -> Void) async throws {
            let selector = NSSelectorFromString("handleEventByInputMethod:completionHandler:")
            let method = try #require(class_getInstanceMethod(NSTextInputContext.self, selector))
            let previous = method_getImplementation(method)
            typealias Completion = @convention(block) (Bool) -> Void
            typealias Handle = @convention(c) (NSTextInputContext, Selector, NSEvent, @escaping Completion) -> Void
            let original = unsafeBitCast(previous, to: Handle.self)
            let replacement: @convention(block) (NSTextInputContext, NSEvent, @escaping Completion) -> Void = { [weak self] context, event, completion in
                original(context, selector, event) { handled in
                    MainActor.assumeIsolated {
                        guard let self else { return completion(handled) }
                        self.answer(event) { completion(handled) }
                    }
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            defer { method_setImplementation(method, previous) }
            try await body()
        }
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
        let stroke = try #require(try BrowserReplKeyStroke.resolve(key: "q", code: "KeyQ", text: "q", modifiers: []))
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
