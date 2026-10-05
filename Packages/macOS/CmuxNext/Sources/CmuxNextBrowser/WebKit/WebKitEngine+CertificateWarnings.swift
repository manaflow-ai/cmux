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
    func forgetCertificateException(host: String, profile: BrowserProfileID) -> Bool {
        certificateExceptions[profile]?.remove(host) != nil
    }

    /// `tab`'s page is from a host whose certificate warning the user
    /// turned off. The interstitial itself is not: the user has not
    /// proceeded yet.
    func certificateWarningsTurnedOff(_ tab: WebKitTab) -> Bool {
        guard tab.state.loadError == nil, let host = tab.state.url?.host() else { return false }
        return hasCertificateException(host, profile: tab.profileID)
    }

    /// The page was loaded past its untrusted certificate: the host is
    /// excepted and WebKit's own evaluation failed (a host whose
    /// certificate became valid again is not broken).
    func loadedPastCertificateWarning(_ tab: WebKitTab) -> Bool {
        let activity = tab.pageInfoActivity
        let failed = activity.failedCertificateReason != nil || !activity.failedCertificateChain.isEmpty
        return failed && certificateWarningsTurnedOff(tab)
    }

    /// Forgets the choice for `tab`'s page host and reloads the page, which
    /// shows the warning again.
    func turnOnCertificateWarnings(_ tab: WebKitTab) -> Bool {
        guard certificateWarningsTurnedOff(tab), let host = tab.state.url?.host(),
              forgetCertificateException(host: host, profile: tab.profileID) else { return false }
        tab.reload()
        return true
    }
}
