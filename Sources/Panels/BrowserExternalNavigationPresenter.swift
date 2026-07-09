import AppKit
import Foundation
import WebKit

/// Presents the AppKit alerts that gate opening an external app from the
/// embedded browser, and resolves the fallback host window used for modal
/// presentation.
///
/// De-free-functioned from `BrowserPanel.swift`. The alert presenter is
/// injected (defaulting to `browserPresentAlert`) so callers can forward their
/// own presentation hook, which makes this a real value type rather than a
/// static-method namespace. The localized strings stay in the app target so
/// `String(localized:)` resolves against the app bundle.
struct BrowserExternalNavigationPresenter {
    /// Alert presenter used for every modal in this presenter; injected so
    /// callers (and tests) can forward an alternate presentation hook.
    let presentAlert: BrowserAlertPresenter

    init(presentAlert: @escaping BrowserAlertPresenter = browserPresentAlert) {
        self.presentAlert = presentAlert
    }

    /// Asks the user whether to open `url` in an external app, reporting the
    /// choice via `completion` (true = open the app, false = stay in browser).
    func presentPrompt(
        for url: URL,
        in webView: WKWebView,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "browser.externalOpenPrompt.title",
            defaultValue: "Open External App?"
        )
        alert.informativeText = String(
            localized: "browser.externalOpenPrompt.message",
            defaultValue: "A web page in cmux wants to open a link in another app. You can stay in the browser instead."
        )
        alert.addButton(withTitle: String(
            localized: "browser.externalOpenPrompt.openApp",
            defaultValue: "Open App"
        ))
        alert.addButton(withTitle: String(
            localized: "browser.externalOpenPrompt.stayInBrowser",
            defaultValue: "Stay in Browser"
        ))

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertFirstButtonReturn)
        }

        presentAlert(alert, webView, handleResponse) {
            completion(false)
        }
    }

    /// Reports that `url` could not be opened, offering to copy it to the
    /// pasteboard.
    func presentFailure(
        for url: URL,
        in webView: WKWebView
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "browser.externalOpenFailure.title",
            defaultValue: "Cannot Open Link"
        )
        alert.informativeText = String(
            localized: "browser.externalOpenFailure.message",
            defaultValue: "cmux could not open this link. You can copy it and open it in another app."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(
            localized: "browser.externalOpenFailure.copyLink",
            defaultValue: "Copy Link"
        ))

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                copyURL(url)
            }
        }

        presentAlert(alert, webView, handleResponse) {}
    }

    private func copyURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Fallback host window when the web view has no usable host window,
    /// preferring the key window and falling back to the main window.
    static func fallbackInteractiveModalHostWindow() -> NSWindow? {
        if let keyWindow = browserInteractiveModalHostWindow(NSApp.keyWindow) {
            return keyWindow
        }
        return browserInteractiveModalHostWindow(NSApp.mainWindow)
    }
}
