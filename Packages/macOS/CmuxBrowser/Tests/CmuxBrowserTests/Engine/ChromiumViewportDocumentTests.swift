import Testing
import WebKit
@testable import CmuxBrowser

@Suite("Chromium viewport document")
@MainActor
struct ChromiumViewportDocumentTests {
    @Test
    func forwardsCompositionAndPasteAsCommittedText() async throws {
        let configuration = WKWebViewConfiguration()
        let messageHandler = ChromiumViewportNoOpMessageHandler()
        configuration.userContentController.add(
            messageHandler,
            name: "cmuxChromiumViewport"
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loadDelegate = ChromiumViewportDocumentLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(
            ChromiumViewportDocument().html(
                loadingText: "Loading",
                accessibilityLabel: "Viewport"
            ),
            in: webView
        )

        let result = try await webView.callAsyncJavaScript(
            """
            window.__cmuxTestMessages = [];
            post = (type, values = {}) => window.__cmuxTestMessages.push({ type, ...values });
            const target = document.getElementById('textInput') || document.getElementById('viewport');
            target.dispatchEvent(new CompositionEvent('compositionstart', { data: '', bubbles: true }));
            target.dispatchEvent(new CompositionEvent('compositionupdate', { data: 'に', bubbles: true }));
            target.dispatchEvent(new CompositionEvent('compositionend', { data: '日本', bubbles: true }));
            const paste = new Event('paste', { bubbles: true, cancelable: true });
            Object.defineProperty(paste, 'clipboardData', {
              value: { getData: type => type === 'text/plain' ? 'pasted text' : '' }
            });
            target.dispatchEvent(paste);
            return window.__cmuxTestMessages;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let messages = try #require(result as? [[String: Any]])

        #expect(messages.compactMap { $0["type"] as? String } == [
            "composition",
            "composition",
            "text",
            "text",
        ])
        #expect(messages.compactMap { $0["text"] as? String } == [
            "に",
            "",
            "日本",
            "pasted text",
        ])
    }
}
