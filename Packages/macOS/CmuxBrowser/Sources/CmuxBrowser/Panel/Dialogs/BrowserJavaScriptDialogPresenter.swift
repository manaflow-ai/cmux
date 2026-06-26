public import Foundation
public import WebKit
import AppKit

/// Presents the JavaScript dialog family (`alert`, `confirm`, `prompt`) and the
/// HTML file `<input type="file">` open panel for a browser web view, matching
/// cmux's main browser chrome.
///
/// The dialog title and button labels are user-facing strings. They are resolved
/// app-side (so `String(localized:)` binds to the app bundle's `.xcstrings`,
/// preserving non-English translations) and passed in: the standard
/// OK / Cancel labels are stored on the presenter, and each call receives its
/// already-localized `dialogTitle` (which depends on the live page URL).
public struct BrowserJavaScriptDialogPresenter: Sendable {
    private let okButtonTitle: String
    private let cancelButtonTitle: String

    /// Creates a presenter carrying the resolved OK / Cancel button labels.
    /// - Parameters:
    ///   - okButtonTitle: Localized label for the confirming button (e.g. "OK").
    ///   - cancelButtonTitle: Localized label for the dismissing button (e.g. "Cancel").
    public init(okButtonTitle: String, cancelButtonTitle: String) {
        self.okButtonTitle = okButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
    }

    /// Presents a `window.alert(...)` dialog (single OK button) and signals
    /// completion once dismissed.
    @MainActor
    public func runAlert(
        message: String,
        dialogTitle: String,
        for webView: WKWebView,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = dialogTitle
        alert.informativeText = message
        alert.addButton(withTitle: okButtonTitle)
        present(alert, for: webView) { _ in completionHandler() }
    }

    /// Presents a `window.confirm(...)` dialog (OK / Cancel) and returns `true`
    /// when the confirming button was chosen.
    @MainActor
    public func runConfirm(
        message: String,
        dialogTitle: String,
        for webView: WKWebView,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = dialogTitle
        alert.informativeText = message
        alert.addButton(withTitle: okButtonTitle)
        alert.addButton(withTitle: cancelButtonTitle)
        present(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    /// Presents a `window.prompt(...)` dialog with a text field (OK / Cancel) and
    /// returns the entered string on OK, or `nil` when cancelled.
    @MainActor
    public func runTextInput(
        prompt: String,
        defaultText: String?,
        dialogTitle: String,
        for webView: WKWebView,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = dialogTitle
        alert.informativeText = prompt
        alert.addButton(withTitle: okButtonTitle)
        alert.addButton(withTitle: cancelButtonTitle)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field

        present(alert, for: webView) { response in
            if response == .alertFirstButtonReturn {
                completionHandler(field.stringValue)
            } else {
                completionHandler(nil)
            }
        }
    }

    /// Presents the file open panel for an HTML `<input type="file">`, honoring the
    /// page's multiple-selection and directory parameters, and returns the chosen
    /// URLs (or `nil` when cancelled).
    @MainActor
    public func runOpenPanel(
        parameters: WKOpenPanelParameters,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    /// Resolves a media-capture (camera/microphone) permission request by always
    /// deferring to WebKit's own prompt, matching the main browser.
    @MainActor
    public func resolveMediaCapture(
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }

    /// Shows the alert as a sheet on the web view's window when available, else as
    /// an application-modal dialog, forwarding the modal response.
    @MainActor
    private func present(
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
}
