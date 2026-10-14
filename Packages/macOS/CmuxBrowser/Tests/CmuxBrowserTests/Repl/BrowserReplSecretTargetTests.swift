import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// A secret is typed only into a frame whose document is on the secret's
/// domains. A frame keeps its id when it navigates, so the frame tree can
/// name a document the frame no longer shows; the check must judge the
/// document that holds the focus, not that record.
@MainActor
@Suite("Browser REPL secret typing target", .serialized)
struct BrowserReplSecretTargetTests {
    /// Collects each frame's `WKFrameInfo` as its document posts its name.
    private final class Frames: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var infos: [String: WKFrameInfo] = [:]
        var finished = false
        private var waiters: [(ready: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let name = message.body as? String { infos[name] = message.frameInfo }
            wake()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
            wake()
        }

        func wait(until ready: @escaping () -> Bool) async {
            if ready() { return }
            await withCheckedContinuation { waiters.append((ready, $0)) }
        }

        private func wake() {
            let (done, pending) = (waiters.filter { $0.ready() }, waiters.filter { !$0.ready() })
            waiters = pending
            done.forEach { $0.continuation.resume() }
        }
    }

    private let frames = Frames()
    private let world = WKContentWorld.world(name: "cmux-secret-target-test")

    private func load(_ body: String, posting names: [String]) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(frames, name: "frame")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = frames
        webView.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: "https://example.test/"))
        let frames = frames
        await frames.wait { frames.finished && names.allSatisfy { frames.infos[$0] != nil } }
        return webView
    }

    private func frame(_ id: String, _ info: WKFrameInfo, parent: String?) -> BrowserReplFrame {
        BrowserReplFrame(frameID: id, parentFrameID: parent, indexInParent: 0, info: info, url: "", name: "", crossOrigin: false)
    }

    /// A web view outside a window never has the system focus, so these
    /// tests count a document's focused field as the focus.
    private func target() throws -> BrowserReplSecretTarget {
        var target = BrowserReplSecretTarget(
            name: "pw",
            domains: [try BrowserReplDomainPattern.parse("example.test", title: "test").json],
            world: world
        )
        target.focusProbe = #"const el = document.activeElement; return !!el && el.tagName === "INPUT";"#
        return target
    }

    private static let focusedField = #"<input id=f><script>document.getElementById('f').focus(); webkit.messageHandlers.frame.postMessage('child')</script>"#

    @Test func aFocusedFieldOnTheDomainTakesTheSecret() async throws {
        let webView = await load(#"<iframe id=child srcdoc="\#(Self.focusedField)"></iframe><script>webkit.messageHandlers.frame.postMessage('main')</script>"#, posting: ["main", "child"])
        let main = try #require(frames.infos["main"])
        let child = try #require(frames.infos["child"])
        try await target().check(in: webView, frames: [frame("1", main, parent: nil), frame("2", child, parent: "1")])
    }

    /// The frame tree was read while the frame showed a page on the domain;
    /// the frame then navigated to a page of another origin with a focused
    /// field. The secret must not be typed there.
    @Test func aFrameThatNavigatedSinceTheTreeReadIsJudgedByItsDocument() async throws {
        let webView = await load(#"<iframe id=child srcdoc="\#(Self.focusedField)"></iframe><script>webkit.messageHandlers.frame.postMessage('main')</script>"#, posting: ["main", "child"])
        let main = try #require(frames.infos["main"])
        let stale = try #require(frames.infos["child"])
        _ = try await webView.callAsyncJavaScript("""
            const child = document.getElementById('child');
            child.removeAttribute('srcdoc');
            child.src = 'data:text/html,<input id=g><script>document.getElementById("g").focus(); webkit.messageHandlers.frame.postMessage("moved")</' + 'script>';
            """, arguments: [:], in: nil, contentWorld: .page)
        let frames = frames
        await frames.wait { frames.infos["moved"] != nil }
        // A cross-origin document's own focus() does not take without a
        // gesture; the page's script in it focuses the field here.
        let moved = try #require(frames.infos["moved"])
        _ = try await webView.callAsyncJavaScript("document.getElementById('g').focus()", arguments: [:], in: moved, contentWorld: .page)
        await #expect(throws: BrowserReplDriverError.self) {
            try await target().check(in: webView, frames: [frame("1", main, parent: nil), frame("2", stale, parent: "1")])
        }
    }

    /// WebKit drops a script's completion when a navigation replaces its
    /// document, and a busy page answers late: the focus probe is bounded,
    /// and one that does not answer refuses the secret with `stale`
    /// instead of hanging the call.
    @Test func aFocusProbeThatNeverAnswersRefusesWithStale() async throws {
        let webView = await load(#"<iframe id=child srcdoc="\#(Self.focusedField)"></iframe><script>webkit.messageHandlers.frame.postMessage('main')</script>"#, posting: ["main", "child"])
        let main = try #require(frames.infos["main"])
        let child = try #require(frames.infos["child"])
        let target = SendableBox(try target())
        let tree = SendableBox([frame("1", main, parent: nil), frame("2", child, parent: "1")])
        let view = SendableBox(webView)
        // The page's web process runs no other script for 8 s, past the
        // 5 s bound.
        BrowserReplFrameGateTests.startBusyLoop(in: webView, seconds: 8)
        let error = await browserReplWithDeadline(seconds: 20) { @MainActor in
            await BrowserReplFrameGateTests.error {
                try await target.value.check(in: view.value, frames: tree.value)
            }
        }
        #expect(error??.code == "stale", "a focus probe that did not answer hung or passed: \(String(describing: error))")
    }
}
