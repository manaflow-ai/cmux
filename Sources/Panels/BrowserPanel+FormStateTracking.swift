import CmuxBrowser
import Foundation
import WebKit

extension BrowserPanel {
    /// Isolated content world shared by the form-state observer, its message
    /// handler and the restore call, so page JavaScript can neither read the
    /// reported input nor post fake reports.
    static let formStateContentWorld = WKContentWorld.world(name: BrowserFormStateScript.messageHandlerName)

    /// Main-frame observer that reports unsaved form input, which a discarded
    /// pane restores after its page comes back.
    static func installFormStateUserScript(into configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserFormStateScript.observerSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: formStateContentWorld
            )
        )
    }

    func setupFormStateMessageHandler(for webView: WKWebView) {
        // The handler outlives this web view generation on the old content
        // controller, so reports from a replaced web view are ignored.
        let boundWebViewInstanceID = webViewInstanceID
        let handler = BrowserFormStateMessageHandler { [weak self] snapshot in
            guard let self, boundWebViewInstanceID == self.webViewInstanceID else { return }
            self.pageRestoration.recordLiveFormState(snapshot)
        }
        pageRestoration.formStateMessageHandler = handler
        webView.configuration.userContentController.add(
            handler,
            contentWorld: Self.formStateContentWorld,
            name: BrowserFormStateScript.messageHandlerName
        )
    }

    func tearDownFormStateMessageHandler(for webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserFormStateScript.messageHandlerName,
            contentWorld: Self.formStateContentWorld
        )
        pageRestoration.formStateMessageHandler = nil
    }

    /// Refills the restored document's unsaved input once it has loaded.
    func applyPendingFormRestore(to webView: WKWebView) {
        guard let formState = pageRestoration.takePendingFormRestore(for: webView.url) else { return }
        webView.callAsyncJavaScript(
            BrowserFormStateScript.restoreFunctionBody,
            arguments: [
                "fields": formState.restorePayload,
                "timeoutMs": BrowserFormStateScript.restoreTimeoutMilliseconds
            ],
            in: nil,
            in: Self.formStateContentWorld
        ) { result in
#if DEBUG
            if case .failure(let error) = result {
                cmuxDebugLog("browser.discard.formRestore failed error=\(error.localizedDescription)")
            }
#else
            _ = result
#endif
        }
    }
}
