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

    @Test
    func evaluationAcceptsStatementsAndTrailingSemicolons() async throws {
        let webView = WKWebView(frame: .zero)
        let loadDelegate = ChromiumViewportDocumentLoadDelegate()
        webView.navigationDelegate = loadDelegate
        defer { webView.navigationDelegate = nil }
        try await loadDelegate.load("<html><body></body></html>", in: webView)
        let session = WebKitBrowserEngineSession(webView: webView)

        let statementResult = try await session.evaluateJavaScript(
            "const answer = 40 + 2; answer;"
        )
        let trailingSemicolonResult = try await session.evaluateJavaScript("42;")

        #expect(statementResult == .number(42))
        #expect(trailingSemicolonResult == .number(42))
    }
}
