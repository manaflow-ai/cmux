import Foundation

enum BrowserWebExtensionCodeSignatureError: LocalizedError {
    case untrustedIdentity
    case invalidSignature

    var errorDescription: String? {
        String(
            localized: "browser.extensions.install.untrustedSafariApp",
            defaultValue: "The Safari extension app could not be verified."
        )
    }
}
