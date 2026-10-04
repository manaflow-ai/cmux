import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// A document of an opaque origin (`data:`, `about:srcdoc` in a sandboxed
/// frame, a `blob:` of an opaque origin) names no host, so the domain policy
/// cannot judge it by its URL or origin. A page the policy blocks could put
/// its content in one (a blocked frame navigates itself to `data:`) and
/// hand it to the session. These tests load real pages in WebKit and require
/// such a document to be judged by the page that made it, and refused under
/// a locked policy when cmux cannot tell who made it.
@MainActor
@Suite("Opaque documents under the domain policy", .serialized)
struct BrowserReplOpaqueDocumentTests {
    /// The blocked frame replaces itself with a `data:` document that
    /// shows its content.
    static let pages = [
        "/": """
            <p>main</p>
            <iframe src="cmux-test://blocked.test/pivot"></iframe>
            <iframe src="cmux-test://allowed.test/pivot"></iframe>
            """,
        "/pivot": #"<script>location.href = "data:text/html,<p>" + location.host + " secret</p>"</script>"#,
    ]

    @Test("A data: document a blocked frame navigated to is judged by that frame")
    func aBlockedPagesDataDocumentIsBlocked() async throws {
        let page = try await OpaquePage.load(recording: true)
        let gate = Self.gate(locked: false)
        let pivot = try #require(page.frame(showing: "blocked.test secret"))
        let error = await Self.error { try await gate.authorize(pivot, in: page.webView) }
        #expect(error?.code == "blocked", "a data: document a blocked page made was authorized")
        #expect(gate.blocked(page.frames, in: page.webView).contains { $0.frame.frameID == pivot.frameID },
                "input and captures would not treat the blocked page's data: document as blocked")
        let read = await Self.error {
            try await gate.callAsyncJavaScript("return document.body.innerText", arguments: [:], in: page.webView, frame: pivot, contentWorld: .page)
        }
        #expect(read?.code == "blocked", "the blocked page's data: document was read")
        // The allowed frame's own data: document stays readable.
        let allowed = try #require(page.frame(showing: "allowed.test secret"))
        #expect(await Self.error { try await gate.authorize(allowed, in: page.webView) } == nil)
    }

    @Test("Under a locked policy an opaque document whose maker is unknown is refused")
    func anUnknownOpaqueDocumentIsRefusedUnderALockedPolicy() async throws {
        // No navigation was recorded: cmux cannot tell who made the documents.
        let page = try await OpaquePage.load(recording: false)
        let pivot = try #require(page.frame(showing: "blocked.test secret"))
        let locked = Self.gate(locked: true)
        let error = await Self.error { try await locked.authorize(pivot, in: page.webView) }
        #expect(error?.code == "blocked", "an opaque document of unknown origin was authorized under a locked policy")
        let allowed = try #require(page.frame(showing: "allowed.test secret"))
        #expect(await Self.error { try await locked.authorize(allowed, in: page.webView) }?.code == "blocked")
        // An unlocked policy the agent can change anyway keeps judging it by its URL.
        let unlocked = Self.gate(locked: false)
        #expect(await Self.error { try await unlocked.authorize(allowed, in: page.webView) } == nil)
    }

    @Test("Under a locked policy the app's own data: document and an allowed page's stay readable")
    func knownOpaqueDocumentsStayReadable() async throws {
        let page = try await OpaquePage.load(recording: true)
        let gate = Self.gate(locked: true)
        let allowed = try #require(page.frame(showing: "allowed.test secret"))
        #expect(await Self.error { try await gate.authorize(allowed, in: page.webView) } == nil)

        let own = try await OpaquePage.load(url: "data:text/html,<p>the agent's own</p>", recording: true)
        #expect(await Self.error { try await gate.authorize(own.main, in: own.webView) } == nil,
                "a data: page the app loaded was refused")
    }

    // MARK: Support

    static func gate(locked: Bool) -> BrowserReplFrameGate {
        let gate = BrowserReplFrameGate(world: BrowserReplFrameGateTests.world)
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try! BrowserReplDomainPattern.parse("cmux-test://blocked.test", title: "test")]
        policy.locked = locked
        gate.policy = policy
        return gate
    }

    static func error(_ body: () async throws -> Any?) async -> BrowserReplDriverError? {
        await BrowserReplFrameGateTests.error(body)
    }
}

/// A page whose child frames navigate themselves to `data:` documents.
@MainActor
struct OpaquePage {
    let webView: WKWebView
    let frames: [BrowserReplFrame]
    let delegate: Recorder

    var main: BrowserReplFrame {
        BrowserReplFrame(frameID: "main", parentFrameID: nil, indexInParent: 0, info: nil,
                         url: webView.url?.absoluteString ?? "", name: "", crossOrigin: false)
    }

    /// The child frame whose `data:` URL carries `text`.
    func frame(showing text: String) -> BrowserReplFrame? {
        frames.dropFirst().first { ($0.url.removingPercentEncoding ?? $0.url).contains(text) }
    }

    /// Records each navigation with ``BrowserReplDocumentProvenance`` when
    /// `recording`, as cmux's navigation delegate does.
    final class Recorder: NSObject, WKNavigationDelegate {
        let recording: Bool
        init(recording: Bool) { self.recording = recording }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if recording { BrowserReplDocumentProvenance.note(navigationAction, in: webView) }
            decisionHandler(.allow)
        }
    }

    static func load(url: String = "cmux-test://allowed.test/", recording: Bool) async throws -> OpaquePage {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(OpaquePageSchemeHandler(), forURLScheme: "cmux-test")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let delegate = Recorder(recording: recording)
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: URL(string: url)!))
        let expected = url.hasPrefix("cmux-test:") ? 3 : 1
        let frames = try await FramePage.settle(webView) { frames in
            frames.count >= expected && frames.dropFirst().allSatisfy { $0.url.hasPrefix("data:") }
                && !(frames.first?.url.isEmpty ?? true)
        }
        return OpaquePage(webView: webView, frames: frames, delegate: delegate)
    }
}

final class OpaquePageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path.isEmpty ? "/" : url.path
        let html = BrowserReplOpaqueDocumentTests.pages[path] ?? "<p>\(url.absoluteString)</p>"
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
        task.didReceive(Data(html.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
