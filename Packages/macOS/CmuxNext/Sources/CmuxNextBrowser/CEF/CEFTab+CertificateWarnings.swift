import Foundation

/// Proceed on cmux's certificate warning page, which an agent-driven tab
/// shows (`ChromiumNetError.proceed`); other tabs show Chromium's interstitial.
extension CEFTab: BrowserCertificateBypassing {
    public func proceedPastCertificateError() { ChromiumNetError.proceed(on: self) }
}

/// Page Info's "Turn on warnings" on Chromium. Chromium keeps the user's
/// Proceed choices (cmux's and its own interstitial's) in its
/// profile (`SSLHostStateDelegate`); CEF can clear them only all at once
/// (`CefRequestContext::ClearCertificateExceptions`), so turning warnings on
/// for one site turns them on for every site of the tab's profile.
extension CEFTab: BrowserCertificateWarningRevoking {
    /// A committed https page whose SSL status has a certificate error
    /// (`syncSecurityFromChromium` made it `.broken`) loaded past the
    /// warning; cmux's warning page is a failed load, not a bypass.
    public var certificateWarningsTurnedOff: Bool {
        state.loadError == nil && state.url?.scheme?.lowercased() == "https" && state.security == .broken
    }

    public var certificateWarningScope: BrowserCertificateWarningScope { .profile }
    /// Chromium does not say which hosts have a Proceed choice: the action
    /// stays enabled and clears them all.
    public var canTurnOnCertificateWarnings: Bool { true }

    public func turnOnCertificateWarnings() async -> Bool {
        guard let browserID, await runtime.clearCertificateExceptions(browserID) else { return false }
        reload()
        return true
    }
}
