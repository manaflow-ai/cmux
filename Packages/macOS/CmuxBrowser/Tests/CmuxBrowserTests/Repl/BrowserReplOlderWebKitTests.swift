import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// The browser REPL on a WebKit that lacks private methods a newer one has.
/// macOS 26.5's WebKit (21624) has neither
/// `_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:`
/// nor `_doAfterProcessingAllPendingKeyEvents:`. The web views here hide one
/// of them (`responds(to:)` says no, as on that WebKit), so these run on any
/// WebKit; a call that skipped the check would still not crash here, so
/// each test checks the behavior the missing method calls for.
@MainActor
@Suite("Browser REPL on an older WebKit", .serialized)
struct BrowserReplOlderWebKitTests {
    /// A web view whose WebKit has no `_callAsyncJavaScript:…withUserGesture:`.
    final class NoGestureChoiceWebView: WKWebView {
        override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == NSSelectorFromString("_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:") {
                return false
            }
            return super.responds(to: aSelector)
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private func load<View: WKWebView>(_ webView: View) async -> View {
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.continuation = continuation
            webView.loadHTMLString("<input id=f value=abc>", baseURL: URL(string: "https://example.com/"))
        }
        webView.navigationDelegate = nil
        return webView
    }

    private static let probe = """
        await new Promise(resolve => queueMicrotask(resolve));
        return { sum: a + b, active: navigator.userActivation.isActive };
        """

    /// The driver's scripts run on that WebKit too, through the method
    /// WebKit's own `callAsyncJavaScript` calls, with its arguments, its
    /// promise awaited, and no user gesture. Before, every driver script
    /// failed there with `unsupported`, so the REPL could do nothing.
    @Test func aScriptWithoutAGestureRunsWhereWebKitHasNoGestureChoice() async throws {
        let webView = await load(NoGestureChoiceWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)))
        let world = WKContentWorld.world(name: "cmux-older-webkit-tests")
        let value = try await webView.browserReplCallAsyncJavaScript(
            Self.probe, arguments: ["a": 2, "b": 3], in: nil, contentWorld: world, userGesture: false
        ) as? [String: Any]
        #expect(value?["sum"] as? Int == 5)
        #expect(value?["active"] as? Bool == false, "a driver script ran in a user gesture")
        // The probe tells a gesture apart: the same script with one is active.
        let withGesture = try await webView.browserReplCallAsyncJavaScript(
            Self.probe, arguments: ["a": 1, "b": 1], in: nil, contentWorld: world, userGesture: true, onlyIf: { true }
        ) as? [String: Any]
        #expect(withGesture?["active"] as? Bool == true)
        // A check that fails at dispatch still keeps the script from the page.
        await #expect(throws: BrowserReplDriverError.self) {
            _ = try await webView.browserReplCallAsyncJavaScript(
                "globalThis.__ran = true; return true", arguments: [:], in: nil, contentWorld: world, userGesture: false, onlyIf: { false }
            )
        }
        #expect(try await webView.evaluateJavaScript("globalThis.__ran === true", in: nil, contentWorld: world) as? Bool == false)
    }

    /// A web view whose WebKit has no `_doAfterProcessingAllPendingKeyEvents:`,
    /// recording the keys it is given and the Edit menu actions run on it.
    final class NoKeyOutcomeWebView: WKWebView {
        var keyDowns: [NSEvent] = []
        var commands: [String] = []
        override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:") { return false }
            return super.responds(to: aSelector)
        }
        override func keyDown(with event: NSEvent) { keyDowns.append(event) }
        override func keyUp(with event: NSEvent) {}
        override func selectAll(_ sender: Any?) { commands.append("selectAll:") }
        @objc(copy:) func countCopy(_ sender: Any?) { commands.append("copy:") }
        @objc(paste:) func countPaste(_ sender: Any?) { commands.append("paste:") }
        @objc(cut:) func countCut(_ sender: Any?) { commands.append("cut:") }
    }

    /// Without that method nothing tells whether a page handled an Edit
    /// shortcut, and guessing either way is wrong: "unhandled" runs Copy or
    /// Paste behind a page that took the key, "handled" silently drops the
    /// command. So `cmux browser press` refuses the shortcut before its key
    /// leaves: no keydown reaches the page, no command runs. Other keys go.
    @Test func cmuxBrowserPressRefusesAnEditShortcutAndSendsNothing() async throws {
        let webView = NoKeyOutcomeWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let meta = try #require(BrowserKeyboardEvent(rawKey: "Meta"))
        let a = try #require(BrowserKeyboardEvent(rawKey: "a"))
        #expect(await webView.replayBrowserKeyboardEvent(meta, action: .keyDown) == .delivered)
        for action in [BrowserKeyboardAction.press, .keyDown] {
            let result = await webView.replayBrowserKeyboardEvent(a, action: action)
            #expect(result != .delivered, "Meta+a (\(action)) was delivered on a WebKit that cannot report its outcome")
        }
        #expect(webView.keyDowns.isEmpty, "the refused shortcut's key reached WebKit")
        #expect(webView.commands.isEmpty, "a refused shortcut ran \(webView.commands)")
        #expect(await webView.replayBrowserKeyboardEvent(meta, action: .keyUp) == .delivered)
        #expect(await webView.replayBrowserKeyboardEvent(a, action: .press) == .delivered)
        #expect(webView.keyDowns.count == 1, "a plain key was not delivered")
    }

    /// The REPL sends a shortcut's key-down through the same call: it must
    /// not run the delivery and must say why.
    @Test func theReplsShortcutDeliveryIsRefusedBeforeItsKeyLeaves() async throws {
        let webView = NoKeyOutcomeWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let stroke = try #require(try BrowserReplKeyStroke.resolve(key: "c", code: "KeyC", text: nil, modifiers: ["Meta"]))
        var delivered = false
        let delivery = await webView.deliverAutomationKeyDown(watchingOutcome: true) {
            delivered = true
            return webView.replayBrowserReplKeyStroke(stroke, keyDown: true, heldBy: "session")
        }
        #expect(!delivered, "the shortcut's key was sent")
        #expect(delivery.result != .delivered)
        #expect(delivery.outcome == nil)
        #expect(webView.keyDowns.isEmpty)
    }
}
