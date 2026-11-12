import AppKit
import CMUXMobileCore
import WebKit

@MainActor
extension BrowserPanel {
    @discardableResult
    func presentMobileBrowserDialog(
        kind: MobileBrowserDialogKind,
        title: String?,
        message: String?,
        host: String?,
        buttons: [MobileBrowserDialogButton],
        textField: MobileBrowserDialogTextField?,
        informational: Bool,
        alert: NSAlert,
        response: @escaping @MainActor (_ buttonID: String, _ text: String?) -> Void,
        macResponse: @escaping @MainActor (NSApplication.ModalResponse) -> (buttonID: String, text: String?),
        cancelButtonID: String
    ) -> MobileBrowserDialogEvent {
        let dialog = mobileBrowserDialogBroker.begin(
            kind: kind,
            title: title,
            message: message,
            host: host,
            buttons: buttons,
            textField: textField,
            informational: informational,
            resolve: response
        )
        // Keep the native completion pending for the CLI. A later reveal must
        // not turn an automation-owned dialog into a sheet on the user's window.
        if browserDialogsOwnedByCLI, Self.isJavaScriptDialog(kind) {
            return dialog
        }
        let broker = mobileBrowserDialogBroker
        let dismiss = presentBrowserAlert(
            alert,
            in: webView,
            completion: { [weak broker] modalResponse in
                let answer = macResponse(modalResponse)
                _ = broker?.respond(MobileBrowserDialogRespondParameters(
                    panelID: dialog.panelID,
                    dialogID: dialog.dialogID,
                    buttonID: answer.buttonID,
                    text: answer.text
                ))
            },
            cancel: { [weak broker] in
                _ = broker?.respond(MobileBrowserDialogRespondParameters(
                    panelID: dialog.panelID,
                    dialogID: dialog.dialogID,
                    buttonID: cancelButtonID,
                    text: nil
                ))
            }
        )
        mobileBrowserDialogBroker.attachDismissal(dialogID: dialog.dialogID, dismissal: dismiss)
        return dialog
    }

    static func isJavaScriptDialog(_ kind: MobileBrowserDialogKind) -> Bool {
        switch kind {
        case .javaScriptAlert, .javaScriptConfirm, .javaScriptPrompt: return true
        default: return false
        }
    }

    var pendingJavaScriptDialogs: [MobileBrowserDialogEvent] {
        mobileBrowserDialogBroker.pendingDialogs.filter { Self.isJavaScriptDialog($0.kind) }
    }

    /// Claims the navigation's JavaScript dialogs together before invoking cancellation callbacks.
    func cancelPendingJavaScriptDialogs() {
        mobileBrowserDialogBroker.resolveAll { Self.isJavaScriptDialog($0.kind) }
    }

    /// Resolves the oldest native JavaScript dialog without evaluating page script.
    func respondToJavaScriptDialog(accept: Bool, text: String?) -> MobileBrowserDialogEvent? {
        guard let dialog = pendingJavaScriptDialogs.first else { return nil }
        let button = dialog.kind == .javaScriptAlert || accept ? "ok" : "cancel"
        guard mobileBrowserDialogBroker.respond(MobileBrowserDialogRespondParameters(
            panelID: dialog.panelID,
            dialogID: dialog.dialogID,
            buttonID: button,
            text: accept ? (text ?? dialog.textField?.initial ?? "") : nil
        )) else { return nil }
        return dialog
    }

    func beginInformationalMobileBrowserDialog(
        kind: MobileBrowserDialogKind,
        title: String?,
        message: String?,
        host: String?,
        cancelLabel: String,
        cancel: @escaping @MainActor () -> Void
    ) -> MobileBrowserDialogEvent {
        mobileBrowserDialogBroker.begin(
            kind: kind,
            title: title,
            message: message,
            host: host,
            buttons: [MobileBrowserDialogButton(id: "cancel", label: cancelLabel, role: .cancel)],
            textField: nil,
            informational: true,
            resolve: { _, _ in cancel() }
        )
    }

    @discardableResult
    func resolveMobileBrowserDialogFromMac(
        _ dialog: MobileBrowserDialogEvent,
        action: @escaping @MainActor () -> Void
    ) -> Bool {
        mobileBrowserDialogBroker.resolveFromMac(dialogID: dialog.dialogID, action: action)
    }

    func presentMobileClientCertificateAlert(
        _ alert: NSAlert,
        webView: WKWebView,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void,
        cancel: @escaping @MainActor () -> Void
    ) {
        let dialog = beginInformationalMobileBrowserDialog(
            kind: .clientCertificate,
            title: alert.messageText,
            message: alert.informativeText,
            host: webView.url?.host,
            cancelLabel: String(localized: "common.cancel", defaultValue: "Cancel"),
            cancel: cancel
        )
        let dismiss = presentBrowserAlert(
            alert,
            in: webView,
            completion: { [weak self] response in
                _ = self?.resolveMobileBrowserDialogFromMac(dialog) {
                    completion(response)
                }
            },
            cancel: { [weak self] in
                _ = self?.resolveMobileBrowserDialogFromMac(dialog, action: cancel)
            }
        )
        mobileBrowserDialogBroker.attachDismissal(dialogID: dialog.dialogID, dismissal: dismiss)
    }
}
