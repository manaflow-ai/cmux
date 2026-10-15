import Foundation
import Testing
import WebKit
import CmuxBrowser

@MainActor
@Suite
struct WebKitBrowserPageTests {
    @MainActor
    private final class RecordingDevTools: WebKitBrowserPageDevToolsControlling {
        var visible = false
        func isDeveloperToolsVisible() -> Bool { visible }
        func showDeveloperTools() -> Bool { visible = true; return true }
        func hideDeveloperTools() -> Bool { visible = false; return true }
    }

    private func makeWebView() -> WKWebView {
        WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: WKWebViewConfiguration())
    }

    @Test func forwardsIdentityAndContentView() {
        let webView = makeWebView()
        let page = WebKitBrowserPage(webView: webView)
        #expect(page.engineKind == .webkit)
        #expect(page.presentation == .inView)
        #expect(page.contentView === webView)
        #expect(page.capabilities.contains(.devTools))
        #expect(!page.capabilities.contains(.devToolsProtocol))
        #expect(!page.capabilities.contains(.trustedInput))
    }

    @Test func zoomForwardsToWebView() {
        let webView = makeWebView()
        let page = WebKitBrowserPage(webView: webView)
        page.pageZoom = 1.25
        #expect(webView.pageZoom == 1.25)
        #expect(page.state.pageZoom == 1.25)
    }

    @Test func devToolsForwardToController() {
        let controller = RecordingDevTools()
        let page = WebKitBrowserPage(webView: makeWebView(), devToolsController: controller)
        #expect(!page.isDevToolsVisible)
        page.showDevTools()
        #expect(page.isDevToolsVisible)
        page.closeDevTools()
        #expect(!page.isDevToolsVisible)
    }

    @Test func unsupportedOperationsThrow() async {
        let page = WebKitBrowserPage(webView: makeWebView())
        await #expect(throws: BrowserEngineError.unsupported("devToolsProtocol")) {
            _ = try await page.sendDevToolsProtocolMessage(method: "Page.enable", params: nil)
        }
        await #expect(throws: BrowserEngineError.unsupported("trustedInput")) {
            try await page.dispatchInput(.insertText("a"))
        }
    }

    @Test func removeAllUserScriptsKeepsScriptsItDidNotAdd() {
        let webView = makeWebView()
        let controller = webView.configuration.userContentController
        let panelScript = WKUserScript(source: "window.panel = 1", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(panelScript)
        let page = WebKitBrowserPage(webView: webView)

        page.addUserScript(BrowserPageUserScript(source: "window.automation = 1", injectionTime: .documentEnd))
        #expect(controller.userScripts.count == 2)

        page.removeAllUserScripts()
        #expect(controller.userScripts.map(\.source) == ["window.panel = 1"])
    }

    @Test func eventsStartWithCurrentStateAndFinishOnClose() async {
        let page = WebKitBrowserPage(webView: makeWebView())
        var iterator = page.events.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .stateChanged(page.state))
        page.close()
        page.close()
        let afterClose = await iterator.next()
        #expect(afterClose == nil)
    }

    @Test func evaluatesJavaScriptInPageWorld() async throws {
        let webView = makeWebView()
        let page = WebKitBrowserPage(webView: webView)
        let value = try await page.evaluateJavaScript("1 + 2", in: .page)
        #expect((value as? NSNumber)?.intValue == 3)
        let isolated = try await page.evaluateJavaScript("'iso'", in: .isolated("cmux-test"))
        #expect(isolated as? String == "iso")
        let undefinedValue = try await page.evaluateJavaScript("undefined", in: .page)
        #expect(undefinedValue == nil)
    }

    @Test func callsAsyncJavaScriptWithArguments() async throws {
        let page = WebKitBrowserPage(webView: makeWebView())
        let value = try await page.callAsyncJavaScript("return a + b;", arguments: ["a": 2, "b": 3], in: .page)
        #expect((value as? NSNumber)?.intValue == 5)
    }
}
