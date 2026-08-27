import AppKit
import CmuxBrowser
import Foundation
import WebKit

@MainActor struct BrowserClientCertificateCredentialPicker {
    private let webView: WKWebView
    private let presentAlert: BrowserAlertPresenter
    private let textFormatter: BrowserAuthPromptTextFormatter

    init(
        webView: WKWebView,
        presentAlert: @escaping BrowserAlertPresenter = browserPresentAlert,
        textFormatter: BrowserAuthPromptTextFormatter = BrowserAuthPromptTextFormatter()
    ) {
        self.webView = webView
        self.presentAlert = presentAlert
        self.textFormatter = textFormatter
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
            Self.dismiss(alert)
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
        textFormatter.origin(
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
           case let title = textFormatter.middleElidedText(rawTitle),
           !title.isEmpty {
            displayTitle = title
        } else {
            let format = String(
                localized: "browser.dialog.clientCertificate.fallbackCertificateName",
                defaultValue: "Certificate %d"
            )
            displayTitle = String(format: format, locale: Locale.current, index + 1)
        }

        guard let subtitle = serialNumberSubtitle(for: candidate) else {
            return displayTitle
        }

        let format = String(
            localized: "browser.dialog.clientCertificate.titleWithSubtitle",
            defaultValue: "%@ (%@)"
        )
        return String(format: format, locale: Locale.current, displayTitle, subtitle)
    }

    private func serialNumberSubtitle(for candidate: BrowserClientCertificateCredentialCandidate) -> String? {
        guard let rawSerialNumber = candidate.serialNumber,
              case let serialNumber = textFormatter.middleElidedText(rawSerialNumber),
              !serialNumber.isEmpty else {
            return nil
        }

        let format = String(
            localized: "browser.dialog.clientCertificate.serialNumber",
            defaultValue: "Serial %@"
        )
        return String(format: format, locale: Locale.current, serialNumber)
    }

    private static func dismiss(_ alert: NSAlert) {
        let window = alert.window
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window, returnCode: .alertSecondButtonReturn)
        } else if window.isVisible {
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
            window.close()
        }
    }
}
