import Testing
import WebKit
@testable import CmuxBrowser

@Suite("Chromium viewport document")
@MainActor
struct ChromiumViewportDocumentTests {
    @Test
    func forwardsCompositionAndPasteAsCommittedText() async throws {
        let webView = try await makeLoadedWebView()

        let result = try await webView.callAsyncJavaScript(
            """
            window.__cmuxTestMessages = [];
            post = (type, values = {}) => window.__cmuxTestMessages.push({ type, ...values });
            const target = document.getElementById('textInput') || document.getElementById('viewport');
            target.dispatchEvent(new InputEvent('beforeinput', {
              inputType: 'insertText', data: 'é', bubbles: true, cancelable: true
            }));
            target.dispatchEvent(new CompositionEvent('compositionstart', { data: '', bubbles: true }));
            target.dispatchEvent(new CompositionEvent('compositionupdate', { data: 'に', bubbles: true }));
            target.dispatchEvent(new CompositionEvent('compositionend', { data: '日本', bubbles: true }));
            target.dispatchEvent(new KeyboardEvent('keydown', {
              key: 'v', code: 'KeyV', metaKey: true, bubbles: true, cancelable: true
            }));
            const paste = new Event('paste', { bubbles: true, cancelable: true });
            Object.defineProperty(paste, 'clipboardData', {
              value: { getData: type => type === 'text/plain' ? 'pasted text' : '' }
            });
            target.dispatchEvent(paste);
            target.dispatchEvent(new KeyboardEvent('keyup', {
              key: 'v', code: 'KeyV', metaKey: true, bubbles: true, cancelable: true
            }));
            return window.__cmuxTestMessages;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let messages = try #require(result as? [[String: Any]])
        let inputMessages = messages.filter {
            guard let type = $0["type"] as? String else { return false }
            return type == "text" || type == "composition"
        }

        #expect(inputMessages.compactMap { $0["type"] as? String } == [
            "text",
            "composition",
            "composition",
            "text",
            "text",
        ])
        #expect(inputMessages.compactMap { $0["text"] as? String } == [
            "é",
            "に",
            "",
            "日本",
            "pasted text",
        ])
    }

    @Test
    func forwardsTheHeldButtonDuringMouseDrag() async throws {
        let webView = try await makeLoadedWebView()
        let result = try await webView.callAsyncJavaScript(
            """
            window.__cmuxTestMessages = [];
            post = (type, values = {}) => window.__cmuxTestMessages.push({ type, ...values });
            document.getElementById('viewport').dispatchEvent(new MouseEvent('mousemove', {
              clientX: 10,
              clientY: 20,
              button: 0,
              buttons: 2,
              bubbles: true
            }));
            return window.__cmuxTestMessages;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let messages = try #require(result as? [[String: Any]])
        let drag = try #require(messages.first { $0["type"] as? String == "mouse" })

        #expect(drag["event"] as? String == "mouseMoved")
        #expect((drag["button"] as? NSNumber)?.intValue == 2)
    }

    private func makeLoadedWebView() async throws -> WKWebView {
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
        return webView
    }
}
