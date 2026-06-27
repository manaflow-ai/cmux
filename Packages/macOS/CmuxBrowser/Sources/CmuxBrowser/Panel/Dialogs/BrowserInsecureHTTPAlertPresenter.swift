public import Foundation
public import WebKit
import AppKit

/// Presents the three-button insecure-HTTP warning alert shown before a popup
/// web view loads a plaintext `http://` URL whose host is not allowlisted,
/// matching cmux's main browser chrome.
///
/// The buttons are "Open in Default Browser", "Proceed in cmux", and "Cancel",
/// plus a suppression checkbox that allowlists the host. All user-facing strings
/// are resolved app-side (so `String(localized:)` binds to the app bundle's
/// `.xcstrings`, preserving non-English translations) and passed in; the message
/// text already has the live host interpolated. Allowlist persistence and the
/// open/proceed/cancel decision are driven through ``BrowserInsecureHTTPSettings``.
public struct BrowserInsecureHTTPAlertPresenter: Sendable {
    private let messageText: String
    private let informativeText: String
    private let openInDefaultBrowserButtonTitle: String
    private let proceedInCmuxButtonTitle: String
    private let cancelButtonTitle: String
    private let alwaysAllowHostButtonTitle: String

    /// Creates a presenter carrying the resolved alert strings.
    /// - Parameters:
    ///   - messageText: Localized alert title (e.g. "Connection isn't secure").
    ///   - informativeText: Localized body with the host already interpolated.
    ///   - openInDefaultBrowserButtonTitle: Label for the first (default) button.
    ///   - proceedInCmuxButtonTitle: Label for the proceed-in-cmux button.
    ///   - cancelButtonTitle: Label for the cancel button.
    ///   - alwaysAllowHostButtonTitle: Title for the suppression checkbox.
    public init(
        messageText: String,
        informativeText: String,
        openInDefaultBrowserButtonTitle: String,
        proceedInCmuxButtonTitle: String,
        cancelButtonTitle: String,
        alwaysAllowHostButtonTitle: String
    ) {
        self.messageText = messageText
        self.informativeText = informativeText
        self.openInDefaultBrowserButtonTitle = openInDefaultBrowserButtonTitle
        self.proceedInCmuxButtonTitle = proceedInCmuxButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
        self.alwaysAllowHostButtonTitle = alwaysAllowHostButtonTitle
    }

    /// Shows the insecure-HTTP warning alert and resolves the navigation policy.
    ///
    /// On dismissal: when the suppression checkbox warrants it, `host` is added to
    /// the allowlist. The first button opens `url` in the default browser and
    /// cancels the popup navigation, the second button proceeds in cmux (`.allow`),
    /// and any other dismissal cancels.
    ///
    /// - Parameters:
    ///   - url: The plaintext HTTP URL being navigated to.
    ///   - host: The normalized host to allowlist when the user opts in.
    ///   - webView: The popup web view whose window hosts the sheet.
    ///   - decisionHandler: Receives the resolved `WKNavigationActionPolicy`.
    @MainActor
    public func present(
        for url: URL,
        host: String,
        in webView: WKWebView,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: openInDefaultBrowserButtonTitle)
        alert.addButton(withTitle: proceedInCmuxButtonTitle)
        alert.addButton(withTitle: cancelButtonTitle)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = alwaysAllowHostButtonTitle

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak alert] response in
            if BrowserInsecureHTTPSettings.shouldPersistAllowlistSelection(
                response: response,
                suppressionEnabled: alert?.suppressionButton?.state == .on
            ) {
                BrowserInsecureHTTPSettings.addAllowedHost(host)
            }
            switch response {
            case .alertFirstButtonReturn:
                // Open in default browser, cancel popup navigation
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            case .alertSecondButtonReturn:
                // Proceed in popup
                decisionHandler(.allow)
            default:
                decisionHandler(.cancel)
            }
        }

        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
            return
        }
        handleResponse(alert.runModal())
    }
}
