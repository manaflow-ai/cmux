import Foundation

// HTTP authentication prompt and the certificate interstitial (WebKit tabs).
extension Strings {
    static func authPrompt(host: String) -> String {
        String(localized: "browser.auth.prompt", defaultValue: "\(host) asks for a user name and password.", bundle: .l10n)
    }
    static func authPromptRealm(host: String, realm: String) -> String {
        String(localized: "browser.auth.promptRealm", defaultValue: "\(host) asks for a user name and password for “\(realm)”.", bundle: .l10n)
    }
    static var authUserName: String { String(localized: "browser.auth.userName", defaultValue: "User Name", bundle: .l10n) }
    static var authPassword: String { String(localized: "browser.auth.password", defaultValue: "Password", bundle: .l10n) }
    static var authSignIn: String { String(localized: "browser.auth.signIn", defaultValue: "Sign In", bundle: .l10n) }

    static var certificateTitle: String {
        String(localized: "browser.certificate.title", defaultValue: "This connection is not private", bundle: .l10n)
    }
    static func certificateMessage(host: String) -> String {
        String(localized: "browser.certificate.message",
               defaultValue: "\(host) uses a certificate this Mac does not trust. Someone may be trying to read or change what you send to it.",
               bundle: .l10n)
    }
    /// A certificate warning action run while no warning page shows.
    static var certificateWarningNotShown: String {
        String(localized: "browser.certificate.notShown", defaultValue: "No certificate warning is showing on this page.", bundle: .l10n)
    }
    static var authRemember: String { String(localized: "browser.auth.remember", defaultValue: "Remember password", bundle: .l10n) }
    static var certificateBackToSafety: String {
        String(localized: "browser.certificate.backToSafety", defaultValue: "Back to Safety", bundle: .l10n)
    }
    static var certificateShowDetails: String {
        String(localized: "browser.certificate.showDetails", defaultValue: "Show Details", bundle: .l10n)
    }
    static var certificateHideDetails: String {
        String(localized: "browser.certificate.hideDetails", defaultValue: "Hide Details", bundle: .l10n)
    }
    /// The interstitial's details: the host and the system's error text.
    static func certificateDetails(host: String, reason: String) -> String {
        String(localized: "browser.certificate.details",
               defaultValue: "cmux could not confirm that this server is \(host). \(reason) Proceed only if you know this server, for example a test server on your own network.",
               bundle: .l10n)
    }
    static func certificateProceed(host: String) -> String {
        String(localized: "browser.certificate.proceed", defaultValue: "Proceed to \(host) (Unsafe)", bundle: .l10n)
    }
}
