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
}
