import AppKit
import Foundation
import WebKit

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

        let finish: (BrowserClientCertificateCredentialCandidate?) -> Void = { selectedCandidate in
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

        presentAlert(alert, webView, handleResponse) {
            finish(nil)
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
        let host = protectionSpace.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayHost: String
        if host.isEmpty {
            displayHost = String(
                localized: "browser.dialog.clientCertificate.unknownHost",
                defaultValue: "This site"
            )
        } else if host.contains(":") && !host.hasPrefix("[") && !host.hasSuffix("]") {
            displayHost = "[\(host)]"
        } else {
            displayHost = host
        }

        let protocolName = protectionSpace.`protocol`?.lowercased()
        let defaultPort: Int?
        switch protocolName {
        case "http":
            defaultPort = 80
        case "https":
            defaultPort = 443
        default:
            defaultPort = nil
        }

        let port = protectionSpace.port
        let authority: String
        if port > 0, port != defaultPort {
            authority = "\(displayHost):\(port)"
        } else {
            authority = displayHost
        }

        guard let protocolName, !protocolName.isEmpty else {
            return authority
        }
        return "\(protocolName)://\(authority)"
    }

    private func title(
        for candidate: BrowserClientCertificateCredentialCandidate,
        at index: Int
    ) -> String {
        let displayTitle: String
        if let title = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            displayTitle = title
        } else {
            let format = String(
                localized: "browser.dialog.clientCertificate.fallbackCertificateName",
                defaultValue: "Certificate %d"
            )
            displayTitle = String(format: format, locale: Locale.current, index + 1)
        }

        guard let subtitle = candidate.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
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
