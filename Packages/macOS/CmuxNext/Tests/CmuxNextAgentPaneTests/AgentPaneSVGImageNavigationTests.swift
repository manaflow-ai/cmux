@testable import CmuxNextAgentPane
import Foundation
import Testing
import WebKit

/// Media-safety plan R7 (leo-workspace#874), observed in WebKit: an agent's SVG drawn as the pane
/// draws it (an `<img>` under the pane's CSP) cannot navigate the page or reach the app, whatever
/// it holds: an `onload` that sets `location`, a `cmux://` link over the whole image, script.
/// Loading it and clicking it make no navigation at all; the first navigation the recorder sees
/// is the test's own sentinel, and the pane's decision cancels every one.
@MainActor
struct AgentPaneSVGImageNavigationTests {
    private static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" onload="top.location='cmux://workspace/ws_x'">\
        <a href="cmux://workspace/ws_0123456789abcdef0123456789abcdef" target="_top"><rect width="40" height="40"/></a>\
        <script>top.location='cmux://session/abc'</script></svg>
        """

    @Test(.timeLimit(.minutes(1))) func anSVGImageWithAnAppLinkAndScriptNavigatesNowhere() async throws {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
        let recorder = Recorder()
        view.navigationDelegate = recorder
        let source = "data:image/svg+xml;base64," + Data(Self.svg.utf8).base64EncodedString()
        let html = """
            <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:">\
            <img id="i" src="\(source)" width="40" height="40">
            """
        try await recorder.load { view.loadHTMLString(html, baseURL: URL(string: "about:blank")) }

        let width = try await view.callAsyncJavaScript("""
            const i = document.getElementById('i');
            if (!i.complete) await new Promise((r) => { i.onload = r; i.onerror = r; });
            i.click();
            const box = i.getBoundingClientRect();
            const at = document.elementFromPoint(box.left + 20, box.top + 20);
            at?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            return i.naturalWidth;
            """, arguments: [:], in: nil, contentWorld: .page) as? Int
        #expect(width == 40, "the SVG did not load as an image")

        // The sentinel: once it arrives, anything the image could have started has been decided.
        try await recorder.sentinel { _ = try? await view.evaluateJavaScript("location.href = 'https://sentinel.invalid/'") }
        #expect(recorder.urls == ["https://sentinel.invalid/"], "\(recorder.urls)")
        let pane = AgentPaneSource.bundled(URL(string: "cmux-agent://pane/index.html")!)
        for text in ["cmux://workspace/ws_x", "cmux://session/abc", "https://sentinel.invalid/"] {
            #expect(AgentPaneNavigation.decision(for: URL(string: text), source: pane, userClicked: false) == .cancel)
        }
        view.navigationDelegate = nil
    }
}

/// Allows the test's own document, then records and cancels every navigation after it.
@MainActor
private final class Recorder: NSObject, WKNavigationDelegate {
    private(set) var urls: [String] = []
    private var loaded = false
    private var finished: CheckedContinuation<Void, any Error>?
    private var sentinelSeen: CheckedContinuation<Void, any Error>?

    func load(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            finished = continuation
            start()
        }
    }

    func sentinel(_ start: @escaping @MainActor () async -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sentinelSeen = continuation
            Task { await start() }
        }
    }

    @objc(webView:decidePolicyForNavigationAction:decisionHandler:)
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard loaded else { return decisionHandler(.allow) }
        let url = action.request.url?.absoluteString ?? ""
        urls.append(url)
        decisionHandler(.cancel)
        if url.hasPrefix("https://sentinel.invalid") {
            sentinelSeen?.resume()
            sentinelSeen = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finished?.resume(throwing: error)
        finished = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finished?.resume(throwing: error)
        finished = nil
    }
}
