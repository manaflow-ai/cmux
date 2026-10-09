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
    @Test("A secret is typed only into a tab the typing session created")
    func secretOnlyInTheSessionsOwnTab() {
        #expect(BrowserReplSecretTarget.tabRefusal(name: "k", creator: "a", sessionID: "a") == nil)
        let user = BrowserReplSecretTarget.tabRefusal(name: "k", creator: nil, sessionID: "a")
        let other = BrowserReplSecretTarget.tabRefusal(name: "k", creator: "b", sessionID: "a")
        #expect(user?.code == "invalid" && user?.message.contains("the user's") == true, "\(String(describing: user))")
        #expect(other?.code == "invalid" && other?.message.contains("another session's") == true, "\(String(describing: other))")
    }

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

    private func load(_ body: String, posting names: [String], baseURL: String = "https://example.test/") async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(frames, name: "frame")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = frames
        webView.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: baseURL))
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
    /// An `<object>` or `<embed>` holds a browsing context like an
    /// `<iframe>`: while focus is in it, the parent's active element is the
    /// object, and the parent must not answer for that focus with its own
    /// origin. Here the tree was read before the embedded frame existed, so
    /// only the parent is asked.
    @Test(arguments: ["object", "embed"])
    func anObjectOrEmbedThatHoldsTheFocusIsNotTheParentsField(_ tag: String) async throws {
        let field = #"<input id=f><script>document.getElementById('f').focus(); webkit.messageHandlers.frame.postMessage('child')</script>"#
        let source = "data:text/html," + (field.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        let element = tag == "object"
            ? #"<object type="text/html" data="\#(source)" width=300 height=100></object>"#
            : #"<embed type="text/html" src="\#(source)" width=300 height=100>"#
        let webView = await load(element + #"<script>webkit.messageHandlers.frame.postMessage('main')</script>"#, posting: ["main", "child"])
        let main = try #require(frames.infos["main"])
        // A web view outside a window has no focused frame, so the parent
        // moves its focus to the element that holds the field's frame, as
        // a click into that frame does.
        let tagName = try await webView.callAsyncJavaScript(
            "const e = document.querySelector('\(tag)'); e.tabIndex = 0; e.focus(); return document.activeElement.tagName",
            contentWorld: .page
        ) as? String
        try #require(tagName == tag.uppercased(), "focus did not move into the \(tag)'s frame (\(tagName ?? "nil"))")
        var target = try target()
        // Any element but the body counts as this document's focus.
        target.focusProbe = "const el = document.activeElement; return !!el && el !== document.body && el !== document.documentElement;"
        var refused: BrowserReplDriverError?
        do {
            try await target.check(in: webView, frames: [frame("1", main, parent: nil)])
        } catch let error as BrowserReplDriverError {
            refused = error
        }
        #expect(refused?.code == "invalid", "the secret went to the field inside the \(tag), judged by the parent's origin")
    }

    /// A page on a host off the secret's domains (`evil.example.test`) can
    /// set `document.domain` to a parent domain that is on them
    /// (`example.test`). The secret must still not reach it: the focused
    /// document is judged by its origin and by its URL's host, so the check
    /// never depends on how WebKit serializes a relaxed origin.
    @Test func aPageThatRelaxedDocumentDomainOntoTheSecretsDomainDoesNotTakeIt() async throws {
        let webView = await load(
            #"<input id=f><script>document.domain = 'example.test'; document.getElementById('f').focus(); webkit.messageHandlers.frame.postMessage('main')</script>"#,
            posting: ["main"],
            baseURL: "https://evil.example.test/"
        )
        let main = try #require(frames.infos["main"])
        let relaxed = try await webView.callAsyncJavaScript("return document.domain", contentWorld: .page) as? String
        try #require(relaxed == "example.test", "the page could not relax document.domain (\(relaxed ?? "nil"))")

        // The domain policy's judge of the same frame: the URL's host is
        // judged with the origin, so the relaxed page stays blocked.
        var policy = BrowserReplDomainPolicy()
        policy.allowed = [try BrowserReplDomainPattern.parse("example.test", title: "test")]
        #expect(policy.blockReason(document: BrowserReplFrameDocument(info: main)) != nil)
        #expect(policy.blockReason(document: BrowserReplFrameDocument(origin: "https://example.test", place: "https://evil.example.test")) != nil,
                "an origin on the policy let a document whose URL host is off it through")

        // As WebKit reports it.
        await #expect(throws: BrowserReplDriverError.self) {
            try await target().check(in: webView, frames: [frame("1", main, parent: nil)])
        }
        // As a WebKit whose `self.origin` followed `document.domain` would
        // report it: the probe's world sees the relaxed origin.
        var relaxedOrigin = try target()
        relaxedOrigin.focusProbe = #"self.origin = "https://example.test"; const el = document.activeElement; return !!el && el.tagName === "INPUT";"#
        await #expect(throws: BrowserReplDriverError.self, "the secret went to evil.example.test on its relaxed origin alone") {
            try await relaxedOrigin.check(in: webView, frames: [frame("1", main, parent: nil)])
        }
    }
}
