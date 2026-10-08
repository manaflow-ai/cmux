import Foundation

// HTTP authentication prompt and the certificate interstitial (WebKit tabs).
extension Strings {
    static func authPrompt(host: String) -> String {
        String(localized: "browser.auth.prompt", defaultValue: "\(host) asks for a user name and password.", bundle: .module)
    }
    static func authPromptRealm(host: String, realm: String) -> String {
        String(localized: "browser.auth.promptRealm", defaultValue: "\(host) asks for a user name and password for “\(realm)”.", bundle: .module)
    }
    static var authUserName: String { String(localized: "browser.auth.userName", defaultValue: "User Name", bundle: .module) }
    static var authPassword: String { String(localized: "browser.auth.password", defaultValue: "Password", bundle: .module) }
    static var authSignIn: String { String(localized: "browser.auth.signIn", defaultValue: "Sign In", bundle: .module) }

    static var certificateTitle: String {
        String(localized: "browser.certificate.title", defaultValue: "This connection is not private", bundle: .module)
    }
    static func certificateMessage(host: String) -> String {
        String(localized: "browser.certificate.message",
               defaultValue: "\(host) uses a certificate this Mac does not trust. Someone may be trying to read or change what you send to it.",
               bundle: .module)
    }
    /// A certificate warning action run while no warning page shows.
    static var certificateWarningNotShown: String {
        String(localized: "browser.certificate.notShown", defaultValue: "No certificate warning is showing on this page.", bundle: .module)
    }
    /// A certificate warning action run on a Chromium page.
    static var certificateWarningChromium: String {
        String(localized: "browser.certificate.chromium", defaultValue: "Chromium shows its own certificate warning page. Use its buttons, or Back.", bundle: .module)
    }
    static var certificateBackToSafety: String { certificateBack }
    static var certificateShowDetails: String { "" }
    static var certificateHideDetails: String { "" }
    static var certificateBack: String { String(localized: "browser.certificate.back", defaultValue: "Go Back", bundle: .module) }
    static func certificateProceed(host: String) -> String {
        String(localized: "browser.certificate.proceed", defaultValue: "Proceed to \(host) (Unsafe)", bundle: .module)
    }
}
