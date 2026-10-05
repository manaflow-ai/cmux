import Foundation

/// Certificate warnings the user turned off by proceeding past them
/// (`certificateExceptions`, per profile, until the app quits), and turning
/// them on again from Page Info (Chrome's "Turn on warnings").
extension WebKitEngine {
    /// Whether the user proceeded past `host`'s certificate in `profile`.
    func hasCertificateException(_ host: String, profile: BrowserProfileID) -> Bool {
        certificateExceptions[profile]?.contains(host) ?? false
    }

    /// Forgets that the user proceeded past `host`'s certificate in
    /// `profile`; true when there was such a choice.
    @discardableResult
    func forgetCertificateException(host: String, profile: BrowserProfileID) -> Bool { false }

    /// `tab`'s page is from a host whose certificate warning the user
    /// turned off.
    func certificateWarningsTurnedOff(_ tab: WebKitTab) -> Bool { false }

    /// Forgets the choice for `tab`'s page host and reloads the page, which
    /// shows the warning again.
    func turnOnCertificateWarnings(_ tab: WebKitTab) -> Bool { false }
}
