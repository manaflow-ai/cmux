import Testing
import WebKit
@testable import CmuxBrowser

@Suite("WebKit browser engine session")
@MainActor
struct WebKitBrowserEngineSessionTests {
    @Test
    func evaluationAwaitsPromiseResolution() async throws {
        let webView = WKWebView(frame: .zero)
        let loadDelegate = ChromiumViewportDocumentLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }
        try await loadDelegate.load("<html><body></body></html>", in: webView)
        let session = WebKitBrowserEngineSession(webView: webView)

        let result = try await session.evaluateJavaScript(
            """
            (async () => {
              await new Promise(resolve => setTimeout(resolve, 1));
              return 42;
            })()
            """
        )

        #expect(result == .number(42))
    }
}
