import Foundation

// HTTP authentication prompt and the certificate interstitial (WebKit tabs).
extension Strings {
    static func authPrompt(host: String) -> String {
        String(localized: "browser.auth.prompt", defaultValue: "\(host) asks for a user name and password.", bundle: .localizedModule)
    }
    static func authPromptRealm(host: String, realm: String) -> String {
        String(localized: "browser.auth.promptRealm", defaultValue: "\(host) asks for a user name and password for “\(realm)”.", bundle: .localizedModule)
    }
    static var authUserName: String { String(localized: "browser.auth.userName", defaultValue: "User Name", bundle: .localizedModule) }
    static var authPassword: String { String(localized: "browser.auth.password", defaultValue: "Password", bundle: .localizedModule) }
    static var authSignIn: String { String(localized: "browser.auth.signIn", defaultValue: "Sign In", bundle: .localizedModule) }

    static var certificateTitle: String {
        String(localized: "browser.certificate.title", defaultValue: "This connection is not private", bundle: .localizedModule)
    }
    static func certificateMessage(host: String) -> String {
        String(localized: "browser.certificate.message",
               defaultValue: "\(host) uses a certificate this Mac does not trust. Someone may be trying to read or change what you send to it.",
               bundle: .localizedModule)
    }
    /// A certificate warning action run while no warning page shows.
    static var certificateWarningNotShown: String {
        String(localized: "browser.certificate.notShown", defaultValue: "No certificate warning is showing on this page.", bundle: .localizedModule)
    }
    static var authRemember: String { String(localized: "browser.auth.remember", defaultValue: "Remember password", bundle: .localizedModule) }
    static var certificateBackToSafety: String {
        String(localized: "browser.certificate.backToSafety", defaultValue: "Back to Safety", bundle: .localizedModule)
    }
    static var certificateShowDetails: String {
        String(localized: "browser.certificate.showDetails", defaultValue: "Show Details", bundle: .localizedModule)
    }
    static var certificateHideDetails: String {
        String(localized: "browser.certificate.hideDetails", defaultValue: "Hide Details", bundle: .localizedModule)
    }
    /// The interstitial's details: the host and the system's error text.
    static func certificateDetails(host: String, reason: String) -> String {
        String(localized: "browser.certificate.details",
               defaultValue: "cmux could not confirm that this server is \(host). \(reason) Proceed only if you know this server, for example a test server on your own network.",
               bundle: .localizedModule)
    }
    static func certificateProceed(host: String) -> String {
        String(localized: "browser.certificate.proceed", defaultValue: "Proceed to \(host) (Unsafe)", bundle: .localizedModule)
    }
}
