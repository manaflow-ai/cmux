import Foundation

/// Page Info's "Turn on warnings" on Chromium. Chromium shows its own
/// certificate interstitial and keeps the user's Proceed choices in its
/// profile (`SSLHostStateDelegate`); CEF can clear them only all at once
/// (`CefRequestContext::ClearCertificateExceptions`), so turning warnings on
/// for one site turns them on for every site of the tab's profile.
extension CEFTab: BrowserCertificateWarningRevoking {
    /// A committed https page whose SSL status has a certificate error
    /// (`syncSecurityFromChromium` made it `.broken`) loaded past the
    /// warning; Chromium's interstitial is a failed load, not a bypass.
    public var certificateWarningsTurnedOff: Bool {
        state.loadError == nil && state.url?.scheme?.lowercased() == "https" && state.security == .broken
    }

    public var certificateWarningScope: BrowserCertificateWarningScope { .site }

    public func turnOnCertificateWarnings() async -> Bool {
        guard certificateWarningsTurnedOff, let browserID, await runtime.clearCertificateExceptions(browserID) else { return false }
        reload()
        return true
    }
}
