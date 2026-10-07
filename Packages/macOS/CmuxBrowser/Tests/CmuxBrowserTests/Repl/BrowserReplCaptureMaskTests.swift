import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// Capture masking in a real web view: a page on a secret's domain that
/// shows the value must render it masked for the whole capture.
@MainActor
@Suite("Browser REPL capture masks", .serialized)
struct BrowserReplCaptureMaskTests {
    static let value = "v4lue-xyz-7731"
    static let prop = "-webkit-text-security"

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

    private var mask: BrowserReplCaptureMask {
        let domains = (try? BrowserReplDomainPattern.parse("example.test", title: "test")).map { [$0.json] } ?? []
        return BrowserReplCaptureMask(secretMasks: [["value": Self.value, "domains": domains]])
    }

    /// The `-webkit-text-security` an element renders with, read by page script.
    private func security(_ expression: String, in webView: WKWebView) async throws -> String? {
        try await webView.callAsyncJavaScript(
            "const el = \(expression); return el ? getComputedStyle(el).getPropertyValue('\(Self.prop)') : 'missing';",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
    }

    private func page(_ script: String, in webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    private static let post = "<script>webkit.messageHandlers.frame.postMessage('main')</script>"

    @Test func textInAClosedShadowRootIsMasked() async throws {
        let webView = await load("""
            <input id=field value="before \(Self.value) after">
            <div id=host></div>
            <script>
            const root = document.getElementById('host').attachShadow({ mode: 'closed' });
            root.innerHTML = '<span id=inner>\(Self.value)</span>';
            window.__closed = root;
            </script>
            \(Self.post)
            """, posting: ["main"])
        let main = try #require(frames.infos["main"])
        let during = try await mask.run(in: webView, frames: { [main] }) {
            (
                field: try await security("document.getElementById('field')", in: webView),
                inner: try await security("window.__closed.getElementById('inner')", in: webView)
            )
        }
        #expect(during.field == "disc")
        #expect(during.inner == "disc", "the value in a closed shadow root rendered unmasked")
        #expect(try await security("window.__closed.getElementById('inner')", in: webView) == "none")
    }

    /// A text node that is a shadow root's own child (a Lit-style component
    /// renders its text that way) has no parent element; its host is what
    /// renders it, so the host is masked and checked.
    @Test func textDirectlyInAShadowRootIsMasked() async throws {
        let webView = await load("""
            <div id=host></div>
            <script>
            const root = document.getElementById('host').attachShadow({ mode: 'closed' });
            root.append(document.createTextNode('\(Self.value)'));
            </script>
            \(Self.post)
            """, posting: ["main"])
        let main = try #require(frames.infos["main"])
        let during = try await mask.run(in: webView, frames: { [main] }) {
            try await security("document.getElementById('host')", in: webView)
        }
        #expect(during == "disc", "a shadow root's own text rendered unmasked")
        #expect(try await security("document.getElementById('host')", in: webView) == "none")
    }

    /// The page drops the mask from a shadow root's text while the capture
    /// runs: the check after the capture finds it and refuses the capture.
    @Test func aShadowRootTextThePageUnmasksRefusesTheCapture() async throws {
        let webView = await load("""
            <div id=host></div>
            <script>
            document.getElementById('host').attachShadow({ mode: 'open' }).append(document.createTextNode('\(Self.value)'));
            </script>
            \(Self.post)
            """, posting: ["main"])
        let main = try #require(frames.infos["main"])
        await #expect(throws: BrowserReplDriverError.self) {
            try await mask.run(in: webView, frames: { [main] }) {
                try await page("document.getElementById('host').style.setProperty('\(Self.prop)', 'none', 'important')", in: webView)
            }
        }
    }

    /// The page drops the mask while the capture runs (a framework that
    /// re-renders the field's style, or page script): the capture may have
    /// drawn the value, so it is refused.
    @Test func aMaskThePageRemovesDuringTheCaptureRefusesIt() async throws {
        let webView = await load("<input id=field value=\"\(Self.value)\">\(Self.post)", posting: ["main"])
        let main = try #require(frames.infos["main"])
        var captured = false
        await #expect(throws: BrowserReplDriverError.self) {
            try await mask.run(in: webView, frames: { [main] }) {
                try await page("document.getElementById('field').style.removeProperty('\(Self.prop)')", in: webView)
                captured = true
            }
        }
        #expect(captured)
        #expect(try await security("document.getElementById('field')", in: webView) == "none")
    }

    /// A value in an element that has no inline style (an element of another
    /// namespace) is masked through its nearest styled ancestor, and does
    /// not stop the scan from masking the elements after it.
    @Test func aValueInAnElementWithoutStyleIsMasked() async throws {
        let webView = await load("""
            <p id=odd></p>
            <p id=after>\(Self.value)</p>
            <script>
            const odd = document.createElementNS('urn:x', 'y');
            odd.textContent = '\(Self.value)';
            document.getElementById('odd').append(odd);
            </script>
            \(Self.post)
            """, posting: ["main"])
        let main = try #require(frames.infos["main"])
        let during = try await mask.run(in: webView, frames: { [main] }) {
            (
                odd: try await security("document.getElementById('odd').firstChild", in: webView),
                after: try await security("document.getElementById('after')", in: webView)
            )
        }
        #expect(during.odd == "disc")
        #expect(during.after == "disc")
    }

    /// A frame keeps its id when it navigates, so the frame list can name a
    /// document of the secret's domain that the frame no longer shows. The
    /// mask goes by the document the frame shows when it runs: a page of
    /// another origin gets no value and no masking that would tell it
    /// where the value is.
    @Test func aFrameThatNavigatedSinceTheListGetsNoValue() async throws {
        let webView = await load("""
            <iframe id=child srcdoc="<script>webkit.messageHandlers.frame.postMessage('child')</script>"></iframe>
            \(Self.post)
            """, posting: ["main", "child"])
        let main = try #require(frames.infos["main"])
        let stale = try #require(frames.infos["child"])
        try await page("""
            const child = document.getElementById('child');
            child.removeAttribute('srcdoc');
            child.src = 'data:text/html,<p id=p>\(Self.value)</p><script>webkit.messageHandlers.frame.postMessage("moved")</script>';
            """, in: webView)
        let frames = frames
        await frames.wait { frames.infos["moved"] != nil }
        let moved = try #require(frames.infos["moved"])
        let during = try await mask.run(in: webView, frames: { [main, stale] }) {
            try await webView.callAsyncJavaScript(
                "return getComputedStyle(document.getElementById('p')).getPropertyValue('\(Self.prop)')",
                arguments: [:], in: moved, contentWorld: .page
            ) as? String
        }
        #expect(during == "none", "a page of another origin was masked with the secret's value")
    }

    /// A frame shows a page of the secret's domain only while the capture
    /// runs, then another page again: it was never masked, so the capture
    /// may show the value, and it is refused.
    @Test func aFrameThatShowsAnotherDocumentDuringTheCaptureRefusesIt() async throws {
        let webView = await load("""
            <iframe id=child src="data:text/html,<script>webkit.messageHandlers.frame.postMessage('child')</script>"></iframe>
            \(Self.post)
            """, posting: ["main", "child"])
        let main = try #require(frames.infos["main"])
        let child = try #require(frames.infos["child"])
        let frames = frames
        var captured = false
        await #expect(throws: BrowserReplDriverError.self) {
            try await mask.run(in: webView, frames: { [main, child] }) {
                try await page("""
                    document.getElementById('child').srcdoc = '<p>\(Self.value)</p><script>webkit.messageHandlers.frame.postMessage("shown")</script>';
                    """, in: webView)
                await frames.wait { frames.infos["shown"] != nil }
                try await page("""
                    const child = document.getElementById('child');
                    child.removeAttribute('srcdoc');
                    child.src = 'data:text/html,<script>webkit.messageHandlers.frame.postMessage("back")</script>';
                    """, in: webView)
                await frames.wait { frames.infos["back"] != nil }
                captured = true
            }
        }
        #expect(captured)
    }

    /// The tab shows a page the domain policy blocks only while the capture
    /// runs: the capture is refused, also with no secret to mask.
    @Test func aBlockedPageShownDuringTheCaptureRefusesIt() async throws {
        let webView = await load(Self.post, posting: ["main"])
        var policy = BrowserReplDomainPolicy()
        policy.allowed = [try BrowserReplDomainPattern.parse("example.test", title: "test")]
        let frames = frames
        var captured = false
        await #expect(throws: BrowserReplDriverError.self) {
            try await BrowserReplCaptureMask(secretMasks: [], policy: policy).run(in: webView, frames: { [nil] }) {
                frames.finished = false
                webView.loadHTMLString(
                    "<p>blocked</p><script>webkit.messageHandlers.frame.postMessage('blocked')</script>",
                    baseURL: URL(string: "https://blocked.test/")
                )
                await frames.wait { frames.finished && frames.infos["blocked"] != nil }
                captured = true
            }
        }
        #expect(captured)
    }

    /// WebKit's frame tree can come back without some child frames (no
    /// tree at all, only the main frame, or a child it cannot describe). A
    /// frame missing from the list is never masked, so a secret in it would
    /// show: the capture is refused instead.
    @Test func aChildFrameMissingFromTheFrameListRefusesTheCapture() async throws {
        let webView = await load("""
            <iframe id=child srcdoc="<p>\(Self.value)</p><script>webkit.messageHandlers.frame.postMessage('child')</script>"></iframe>
            \(Self.post)
            """, posting: ["main", "child"])
        let main = try #require(frames.infos["main"])
        var captured = false
        let error = await BrowserReplFrameGateTests.error {
            try await mask.run(in: webView, frames: { [main] }) { captured = true }
        }
        #expect(error != nil, "a capture was taken while a child frame holding a secret was missing from the frame list")
        #expect(!captured)
        // The whole list lets it through.
        let child = try #require(frames.infos["child"])
        #expect(await BrowserReplFrameGateTests.error {
            try await mask.run(in: webView, frames: { [main, child] }) { captured = true }
        } == nil)
        #expect(captured)
    }

    // MARK: Blocked child frames

    /// A frame keeps its id when it navigates, so a child frame can show a
    /// page the policy blocks after the driver judged the tree and before
    /// the mask marks it. A PDF cannot blank a frame, so a child frame whose
    /// marked document is blocked refuses it.
    @Test func aPDFOfAChildFrameWhoseDocumentIsBlockedIsRefused() async throws {
        let page = try await FramePage.load()
        let mask = BrowserReplCaptureMask(secretMasks: [], policy: Self.policy(prohibiting: "cmux-test://blocked.test"), blockedChildFrames: .refuse)
        var captured = false
        let error = await BrowserReplFrameGateTests.error {
            try await mask.run(in: page.webView, frames: { page.frames.map(\.info) }) { captured = true }
        }
        #expect(error?.code == "blocked", "a PDF of a blocked child frame was allowed: \(String(describing: error))")
        #expect(!captured)
    }

    /// A screenshot blanks blocked frames itself: the mask hands it each
    /// child frame whose marked document the policy blocks, so a frame that
    /// navigated to a blocked page after the tree was judged is blanked too.
    @Test func aScreenshotIsHandedTheChildFramesWhoseDocumentIsBlocked() async throws {
        let page = try await FramePage.load()
        let blocked = try #require(page.frame(host: "blocked.test"))
        let allowed = try #require(page.frame(path: "/child"))
        let mask = BrowserReplCaptureMask(secretMasks: [], policy: Self.policy(prohibiting: "cmux-test://blocked.test"), blockedChildFrames: .handToCapture)
        let handed = try await mask.run(in: page.webView, frames: { page.frames.map(\.info) }) { blockedChildFrames in
            blockedChildFrames
        }
        #expect(handed[blocked.frameID] != nil, "the blocked child frame was not handed to the screenshot: \(handed)")
        #expect(handed[allowed.frameID] == nil, "an allowed child frame was handed to the screenshot as blocked")
    }

    /// A child frame the mask marked can show a page the policy blocks
    /// during the capture (a response WebKit accepted before the load hold
    /// commits) and be removed before the check after it, which then finds
    /// no frame to refuse the capture for. A marked frame missing after the
    /// capture refuses it.
    @Test func aMarkedFrameRemovedDuringTheCaptureRefusesIt() async throws {
        let page = try await FramePage.load()
        let webView = page.webView
        let mask = BrowserReplCaptureMask(secretMasks: [], policy: Self.policy(prohibiting: "cmux-test://blocked.test"), blockedChildFrames: .handToCapture)
        var captured = false
        let error = await BrowserReplFrameGateTests.error {
            try await mask.run(in: webView, frames: { await BrowserReplFrame.readTree(of: webView).map(\.info) }) { _ in
                _ = try await page.run(#"document.getElementById("a").src = "cmux-test://blocked.test/late"; return true"#, in: page.main)
                _ = try await FramePage.settle(webView) { frames in frames.contains { $0.url == "cmux-test://blocked.test/late" } }
                captured = true
                _ = try await page.run(#"document.getElementById("a").remove(); return true"#, in: page.main)
                _ = try await FramePage.settle(webView) { frames in !frames.contains { $0.url == "cmux-test://blocked.test/late" } }
                return true
            }
        }
        #expect(captured)
        #expect(error?.code == "stale", "a capture that showed a blocked page in a frame removed before the check was returned: \(String(describing: error))")
    }

    // MARK: Scripts that never answer

    /// WebKit drops a script's completion when a navigation replaces its
    /// document, and a busy page answers late: the mask's scripts are
    /// bounded, and one that does not answer refuses the capture with
    /// `stale` instead of hanging it.
    @Test func aMaskScriptThatNeverAnswersRefusesWithStale() async throws {
        let page = try await FramePage.load()
        let mask = BrowserReplCaptureMask(secretMasks: [], policy: Self.policy(prohibiting: "cmux-test://other.test"))
        let infos = SendableBox(page.frames.map(\.info))
        let webView = SendableBox(page.webView)
        // The page's web process runs no other script for 8 s, past the
        // 5 s bound.
        BrowserReplFrameGateTests.startBusyLoop(in: page.webView, seconds: 8)
        let error = await browserReplWithDeadline(seconds: 20) { @MainActor in
            await BrowserReplFrameGateTests.error {
                try await mask.run(in: webView.value, frames: { infos.value }) { true }
            }
        }
        #expect(error??.code == "stale", "a mask script that did not answer hung or passed: \(String(describing: error))")
    }

    static func policy(prohibiting pattern: String) -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try! BrowserReplDomainPattern.parse(pattern, title: "test")]
        return policy
    }

    /// The mask step fails in a frame on the secret's domain (here the frame
    /// went away after the frame list was read): the capture is refused
    /// rather than taken with that frame unmasked.
    @Test func aMaskStepThatFailsRefusesTheCapture() async throws {
        let webView = await load("""
            <p>\(Self.value)</p>
            <iframe id=child srcdoc="<p>\(Self.value)</p><script>webkit.messageHandlers.frame.postMessage('child')</script>"></iframe>
            \(Self.post)
            """, posting: ["main", "child"])
        let main = try #require(frames.infos["main"])
        let child = try #require(frames.infos["child"])
        try await page("document.getElementById('child').remove()", in: webView)
        var captured = false
        await #expect(throws: BrowserReplDriverError.self) {
            try await mask.run(in: webView, frames: { [main, child] }) { captured = true }
        }
        #expect(!captured)
        #expect(try await security("document.querySelector('p')", in: webView) == "none")
    }
}
