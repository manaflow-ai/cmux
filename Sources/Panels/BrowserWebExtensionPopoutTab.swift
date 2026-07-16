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
        controller?.owns(context) == true ? controller : nil
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        controller?.owns(context) == true ? 0 : NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        controller?.owns(context) == true ? controller?.webView : nil
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        controller?.owns(context) == true ? controller?.webView.url : nil
    }

    func title(for context: WKWebExtensionContext) -> String? {
        controller?.owns(context) == true ? controller?.webView.title : nil
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        controller?.owns(context) == true
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard controller?.owns(context) == true,
              let webView = controller?.webView else { return true }
        return !webView.isLoading
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let controller,
              controller.owns(context),
              controller.canLoadExtensionRequestedURL(url) else {
            completionHandler(NSError(domain: "cmux.webExtension.popup", code: 1))
            return
        }
        controller.webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let controller, controller.owns(context) else {
            completionHandler(NSError(domain: "cmux.webExtension.popup", code: 2))
            return
        }
        controller.closeFromExtensionOrUser()
        completionHandler(nil)
    }
}
