import AppKit
import Foundation
import WebKit

private let browserHTTPBasicAuthPromptTextMaxLength = 240

private let browserHTTPBasicAuthPromptDangerousScalars: Set<Unicode.Scalar> = [
    "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
    "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
    "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    "\u{FEFF}",
]

private func browserFilteredHTTPBasicAuthPromptText(_ text: String) -> String {
    let filtered = String(text.unicodeScalars.filter { scalar in
        !browserHTTPBasicAuthPromptDangerousScalars.contains(scalar)
            && !CharacterSet.controlCharacters.contains(scalar)
    })
    return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func browserSanitizedHTTPBasicAuthPromptText(_ text: String) -> String {
    let trimmed = browserFilteredHTTPBasicAuthPromptText(text)
    guard trimmed.count > browserHTTPBasicAuthPromptTextMaxLength else {
        return trimmed
    }
    return String(trimmed.prefix(browserHTTPBasicAuthPromptTextMaxLength))
}

private func browserMiddleElidedHTTPBasicAuthPromptText(_ text: String) -> String {
    let trimmed = browserFilteredHTTPBasicAuthPromptText(text)
    guard trimmed.count > browserHTTPBasicAuthPromptTextMaxLength else {
        return trimmed
    }

    let marker = "..."
    let keptCharacterCount = browserHTTPBasicAuthPromptTextMaxLength - marker.count
    let prefixCount = min(48, max(16, keptCharacterCount / 3))
    let suffixCount = max(0, keptCharacterCount - prefixCount)
    return String(trimmed.prefix(prefixCount)) + marker + String(trimmed.suffix(suffixCount))
}

private func browserDefaultPort(forHTTPBasicAuthProtocol protocolName: String?) -> Int? {
    switch protocolName?.lowercased() {
    case "http":
        return 80
    case "https":
        return 443
    default:
        return nil
    }
}

private func browserHTTPBasicAuthPromptOrigin(
    protectionSpace: URLProtectionSpace
) -> String {
    let host = browserFilteredHTTPBasicAuthPromptText(protectionSpace.host)
    guard !host.isEmpty else {
        return String(
            localized: "browser.dialog.auth.basic.unknownHost",
            defaultValue: "this site"
        )
    }

    let rawProtocol = protectionSpace.`protocol` ?? ""
    let protocolName = browserFilteredHTTPBasicAuthPromptText(rawProtocol).lowercased()
    let defaultPort = browserDefaultPort(forHTTPBasicAuthProtocol: protocolName)

    let displayHost: String
    if host.contains(":") && !host.hasPrefix("[") && !host.hasSuffix("]") {
        displayHost = "[\(host)]"
    } else {
        displayHost = host
    }

    let port = protectionSpace.port
    let authority: String
    if port > 0, port != defaultPort {
        authority = "\(displayHost):\(port)"
    } else {
        authority = displayHost
    }

    let origin = protocolName.isEmpty ? authority : "\(protocolName)://\(authority)"
    return browserMiddleElidedHTTPBasicAuthPromptText(origin)
}

private func browserHTTPBasicAuthPromptMessage(
    challenge: URLAuthenticationChallenge
) -> String {
    let origin = browserHTTPBasicAuthPromptOrigin(protectionSpace: challenge.protectionSpace)
    if let rawRealm = challenge.protectionSpace.realm {
        let realm = browserSanitizedHTTPBasicAuthPromptText(rawRealm)
        guard !realm.isEmpty else {
            let format = String(
                localized: "browser.dialog.auth.basic.messageHost",
                defaultValue: "%@ requires a username and password."
            )
            return String(format: format, locale: Locale.current, origin)
        }
        let format = String(
            localized: "browser.dialog.auth.basic.messageHostAndRealm",
            defaultValue: "%1$@ requires a username and password for \"%2$@\"."
        )
        return String(format: format, locale: Locale.current, origin, realm)
    }

    let format = String(
        localized: "browser.dialog.auth.basic.messageHost",
        defaultValue: "%@ requires a username and password."
    )
    return String(format: format, locale: Locale.current, origin)
}

private func browserDismissHTTPBasicAuthPrompt(_ alert: NSAlert) {
    let window = alert.window
    if let sheetParent = window.sheetParent {
        sheetParent.endSheet(window, returnCode: .alertSecondButtonReturn)
    } else if window.isVisible {
        NSApp.stopModal(withCode: .alertSecondButtonReturn)
        window.close()
    }
}

@MainActor
func browserHandleHTTPBasicAuthenticationChallenge(
    in webView: WKWebView,
    challenge: URLAuthenticationChallenge,
    alertFactory: @escaping @MainActor () -> NSAlert = { NSAlert() },
    windowProvider: (() -> NSWindow?)? = nil,
    presentAlert: @escaping BrowserAlertPresenter = browserPresentAlert,
    registerCancelPrompt: ((@escaping () -> Void) -> Void)? = nil,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) -> Bool {
    guard browserShouldPromptForHTTPBasicAuth(challenge: challenge) else {
        return false
    }

    let presentPrompt = {
        let alert = alertFactory()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "browser.dialog.auth.basic.title",
            defaultValue: "Authentication Required"
        )
        let promptMessage = browserHTTPBasicAuthPromptMessage(challenge: challenge)
        let accessoryMessage: String
        if challenge.previousFailureCount > 0 {
            let failureMessage = String(
                localized: "browser.dialog.auth.basic.incorrectCredentials",
                defaultValue: "The username or password you entered is incorrect."
            )
            accessoryMessage = "\(failureMessage)\n\n\(promptMessage)"
        } else {
            accessoryMessage = promptMessage
        }
        alert.informativeText = ""
        alert.addButton(
            withTitle: String(
                localized: "browser.dialog.auth.basic.signIn",
                defaultValue: "Sign In"
            )
        )
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let accessoryWidth: CGFloat = 320

        let messageLabel = NSTextField(wrappingLabelWithString: accessoryMessage)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping

        let usernameField = NSTextField(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 24))
        usernameField.stringValue = challenge.proposedCredential?.user ?? ""
        usernameField.placeholderString = String(localized: "browser.dialog.auth.basic.username", defaultValue: "Username")
        usernameField.translatesAutoresizingMaskIntoConstraints = false

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 24))
        passwordField.stringValue = challenge.proposedCredential?.password ?? ""
        passwordField.placeholderString = String(localized: "browser.dialog.auth.basic.password", defaultValue: "Password")
        passwordField.translatesAutoresizingMaskIntoConstraints = false

        let formStack = NSStackView(views: [messageLabel, usernameField, passwordField])
        formStack.orientation = .vertical
        formStack.alignment = .width
        formStack.distribution = .fill
        formStack.spacing = 8
        formStack.translatesAutoresizingMaskIntoConstraints = false

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 1))
        accessoryView.addSubview(formStack)

        NSLayoutConstraint.activate([
            formStack.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            formStack.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            formStack.bottomAnchor.constraint(equalTo: accessoryView.bottomAnchor),
            formStack.widthAnchor.constraint(equalToConstant: accessoryWidth),
            usernameField.heightAnchor.constraint(equalToConstant: 28),
            passwordField.heightAnchor.constraint(equalToConstant: 28),
        ])

        accessoryView.layoutSubtreeIfNeeded()
        accessoryView.setFrameSize(accessoryView.fittingSize)
        alert.accessoryView = accessoryView

        var didComplete = false
        let completeOnce: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, credential in
            guard !didComplete else { return }
            didComplete = true
            completionHandler(disposition, credential)
        }
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                let credential = URLCredential(
                    user: usernameField.stringValue,
                    password: passwordField.stringValue,
                    persistence: .forSession
                )
                completeOnce(.useCredential, credential)
            } else {
                completeOnce(.cancelAuthenticationChallenge, nil)
            }
        }

        let handleCancel = {
            completeOnce(.cancelAuthenticationChallenge, nil)
        }

        registerCancelPrompt? {
            browserDismissHTTPBasicAuthPrompt(alert)
            handleCancel()
        }

        if let windowProvider {
            if let window = windowProvider() {
                alert.beginSheetModal(for: window, completionHandler: handleResponse)
            } else {
                handleResponse(alert.runModal())
            }
        } else {
            presentAlert(alert, webView, handleResponse, handleCancel)
        }
    }

    presentPrompt()
    return true
}
