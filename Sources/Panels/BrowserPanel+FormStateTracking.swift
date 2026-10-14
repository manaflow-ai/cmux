import CmuxBrowser
import Foundation
import WebKit

extension BrowserPanel {
    /// Main-frame observer that reports unsaved form input, which a discarded
    /// pane restores after its page comes back.
    static func installFormStateUserScript(into configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(.browserFormStateObserver())
    }

    func setupFormStateMessageHandler(for webView: WKWebView) {
        // The handler outlives this web view generation on the old content
        // controller, so reports from a replaced web view are ignored.
        let boundWebViewInstanceID = webViewInstanceID
        let handler = BrowserFormStateMessageHandler(webView: webView) { [weak self] snapshot in
            guard let self, boundWebViewInstanceID == self.webViewInstanceID else { return }
            let hadUnrestorableInput = self.pageRestoration.hasUnrestorableLiveInput
            self.pageRestoration.recordLiveFormState(snapshot)
            // Input a restore would lose keeps a hidden pane from a routine
            // discard, so a timer armed without it must be re-evaluated.
            if self.pageRestoration.hasUnrestorableLiveInput != hadUnrestorableInput {
                self.reevaluateHiddenWebViewDiscardScheduling(reason: "form_input_changed")
            }
        }
        pageRestoration.formStateMessageHandler = handler
        webView.configuration.userContentController.addBrowserFormStateHandler(handler)
    }

    func tearDownFormStateMessageHandler(for webView: WKWebView) {
        webView.configuration.userContentController.removeBrowserFormStateHandler()
        pageRestoration.formStateMessageHandler = nil
    }

    /// Refills the restored document's unsaved input once it has loaded.
    func applyPendingFormRestore(to webView: WKWebView) {
        guard let formState = pageRestoration.takePendingFormRestore(for: webView.url) else { return }
        webView.restoreBrowserFormState(formState) { error in
            self.pageRestoration.retryPendingFormRestore(formState)
#if DEBUG
            cmuxDebugLog("browser.discard.formRestore failed error=\(error.localizedDescription)")
#else
            _ = error
#endif
        }
    }
}
