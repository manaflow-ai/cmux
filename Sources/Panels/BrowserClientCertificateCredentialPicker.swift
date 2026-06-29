import AppKit
import Foundation
import WebKit

private func browserDismissClientCertificateCredentialPicker(_ alert: NSAlert) {
    let window = alert.window
    if let sheetParent = window.sheetParent {
        sheetParent.endSheet(window, returnCode: .alertSecondButtonReturn)
    } else if window.isVisible {
        NSApp.stopModal(withCode: .alertSecondButtonReturn)
        window.close()
    }
}

@MainActor struct BrowserClientCertificateCredentialPicker {
    private let webView: WKWebView
    private let presentAlert: BrowserAlertPresenter

    init(
        webView: WKWebView,
        presentAlert: @escaping BrowserAlertPresenter = browserPresentAlert
    ) {
        self.webView = webView
        self.presentAlert = presentAlert
    }

    func selectCredential(
        for protectionSpace: URLProtectionSpace,
        candidates: [BrowserClientCertificateCredentialCandidate],
        registerCancelPrompt: ((@escaping () -> Void) -> Void)? = nil,
        completion: @escaping (BrowserClientCertificateCredentialCandidate?) -> Void
    ) {
        guard !candidates.isEmpty else {
            completion(nil)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "browser.dialog.clientCertificate.title",
            defaultValue: "Choose a Certificate"
        )
        alert.informativeText = message(for: protectionSpace)
        alert.addButton(withTitle: String(
            localized: "browser.dialog.clientCertificate.continue",
            defaultValue: "Continue"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28), pullsDown: false)
        popup.addItems(withTitles: candidates.enumerated().map { index, candidate in
            title(for: candidate, at: index)
        })
        popup.selectItem(at: 0)
        alert.accessoryView = popup

        var didComplete = false
        let finish: (BrowserClientCertificateCredentialCandidate?) -> Void = { selectedCandidate in
            guard !didComplete else { return }
            didComplete = true
            completion(selectedCandidate)
        }
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                finish(nil)
                return
            }
            let selectedIndex = popup.indexOfSelectedItem
            guard candidates.indices.contains(selectedIndex) else {
                finish(nil)
                return
            }
            finish(candidates[selectedIndex])
        }

        let handleCancel = {
            finish(nil)
        }

        registerCancelPrompt? {
            browserDismissClientCertificateCredentialPicker(alert)
            handleCancel()
        }

        presentAlert(alert, webView, handleResponse) {
            handleCancel()
        }
    }

    private func message(for protectionSpace: URLProtectionSpace) -> String {
        let format = String(
            localized: "browser.dialog.clientCertificate.message",
            defaultValue: "%@ requires a client certificate."
        )
        return String(format: format, locale: Locale.current, origin(for: protectionSpace))
    }

    private func origin(for protectionSpace: URLProtectionSpace) -> String {
        browserAuthPromptOrigin(
            protectionSpace: protectionSpace,
            unknownHost: String(
                localized: "browser.dialog.clientCertificate.unknownHost",
                defaultValue: "This site"
            )
        )
    }

    private func title(
        for candidate: BrowserClientCertificateCredentialCandidate,
        at index: Int
    ) -> String {
        let displayTitle: String
        if let rawTitle = candidate.title,
           case let title = browserAuthPromptMiddleElidedText(rawTitle),
           !title.isEmpty {
            displayTitle = title
        } else {
            let format = String(
                localized: "browser.dialog.clientCertificate.fallbackCertificateName",
                defaultValue: "Certificate %d"
            )
            displayTitle = String(format: format, locale: Locale.current, index + 1)
        }

        guard let rawSubtitle = candidate.subtitle,
              case let subtitle = browserAuthPromptMiddleElidedText(rawSubtitle),
              !subtitle.isEmpty else {
            return displayTitle
        }

        let format = String(
            localized: "browser.dialog.clientCertificate.titleWithSubtitle",
            defaultValue: "%@ (%@)"
        )
        return String(format: format, locale: Locale.current, displayTitle, subtitle)
    }
}
