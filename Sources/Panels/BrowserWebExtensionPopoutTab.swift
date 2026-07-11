import Foundation
import WebKit

/// The extension-page tab owned by a browser web-extension popout window.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionPopoutTab: NSObject, WKWebExtensionTab {
    private weak var controller: BrowserWebExtensionPopoutWindowController?

    init(controller: BrowserWebExtensionPopoutWindowController) {
        self.controller = controller
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        controller
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        controller?.webView
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        controller?.webView.url
    }

    func title(for context: WKWebExtensionContext) -> String? {
        controller?.webView.title
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard let webView = controller?.webView else { return true }
        return !webView.isLoading
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let controller,
              controller.canLoadExtensionRequestedURL(url) else {
            completionHandler(NSError(domain: "cmux.webExtension.popup", code: 1))
            return
        }
        controller.webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        controller?.closeFromExtensionOrUser()
        completionHandler(nil)
    }
}
