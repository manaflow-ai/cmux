import AppKit
import CmuxFoundation
import Foundation
import WebKit

/// Handles browser-window behavior initiated by a web-extension popout page.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionPopoutUIDelegate: NSObject, WKUIDelegate {
    var closeAction: () -> Void
    var newWindowAction: (URLRequest) -> Void
    var scriptedPopupAction: (URLRequest, WKWebViewConfiguration, WKWindowFeatures) -> WKWebView?

    init(
        closeAction: @escaping () -> Void = {},
        newWindowAction: @escaping (URLRequest) -> Void = { _ in },
        scriptedPopupAction: @escaping (URLRequest, WKWebViewConfiguration, WKWindowFeatures) -> WKWebView? = { _, _, _ in nil }
    ) {
        self.closeAction = closeAction
        self.newWindowAction = newWindowAction
        self.scriptedPopupAction = scriptedPopupAction
    }

    func webViewDidClose(_ webView: WKWebView) {
        closeAction()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let isScriptedPopup = browserNavigationShouldCreatePopup(
            navigationType: navigationAction.navigationType,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            popupFeaturesWereSpecified: browserNavigationPopupFeaturesWereSpecified(
                windowFeatures: windowFeatures
            )
        )
        if isScriptedPopup {
            return createScriptedPopup(
                request: navigationAction.request,
                configuration: configuration,
                windowFeatures: windowFeatures
            )
        }
        handleNewWindowRequest(navigationAction.request)
        return nil
    }

    func createScriptedPopup(
        request: URLRequest,
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        scriptedPopupAction(request, configuration, windowFeatures)
    }

    func handleNewWindowRequest(_ request: URLRequest) {
        newWindowAction(request)
    }

    func javaScriptDialogTitle(for url: URL?) -> String {
        if let absolute = url?.absoluteString, !absolute.isEmpty {
            return String.localizedStringWithFormat(
                String(
                    localized: "browser.dialog.pageSaysAt",
                    defaultValue: "The page at %@ says:"
                ),
                absolute
            )
        }
        return String(
            localized: "browser.dialog.pageSays",
            defaultValue: "This page says:"
        )
    }

    private func presentDialog(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
            return
        }
        completion(alert.runModal())
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: frame.request.url)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        presentDialog(alert, for: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: frame.request.url)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        presentDialog(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = javaScriptDialogTitle(for: frame.request.url)
        alert.informativeText = prompt
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.font = GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize)
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field

        presentDialog(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }
}
