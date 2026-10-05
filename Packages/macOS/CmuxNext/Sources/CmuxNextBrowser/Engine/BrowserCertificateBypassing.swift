public import Foundation

/// A tab that can load a page whose TLS certificate the system does not
/// trust, after the user chose Proceed on the interstitial (WebKit; the
/// Chromium engine shows its own interstitial).
public protocol BrowserCertificateBypassing: AnyObject {
    /// Trusts the failing page's host for this browser profile until the
    /// app quits, and loads the page again.
    func proceedPastCertificateError()
}

/// A tab that can turn certificate warnings on again for a site the user
/// proceeded past (Chrome's Page Info "Turn on warnings"; Safari forgets the
/// choice at quit). Both engines conform: WebKit keeps cmux's own per-profile
/// exception set, Chromium its own allow decisions.
public protocol BrowserCertificateWarningRevoking: AnyObject {
    /// The page on screen is from a site whose certificate warning the user
    /// turned off by proceeding past it.
    var certificateWarningsTurnedOff: Bool { get }
    /// What turning the warnings on covers: WebKit forgets the page's host
    /// only; Chromium can clear only every Proceed choice of the profile.
    var certificateWarningScope: BrowserCertificateWarningScope { get }
    /// The engine knows a choice to forget for this page: WebKit, a
    /// Proceed for the page's host in its own exception set; Chromium has
    /// no per-host knowledge, so always (it clears the whole profile).
    /// While false, the action is disabled in every surface.
    var canTurnOnCertificateWarnings: Bool { get }
    /// Turns the warnings on again for the page's site in this tab's
    /// profile, then reloads, so the warning shows again. False when there
    /// was nothing to turn on or the engine could not do it.
    func turnOnCertificateWarnings() async -> Bool
}

/// What "Turn on warnings" turns on again.
public nonisolated enum BrowserCertificateWarningScope: Hashable, Sendable {
    /// The page's site in the tab's profile (WebKit).
    case site
    /// Every site of the tab's profile (Chromium:
    /// `CefRequestContext::ClearCertificateExceptions`).
    case profile
}
