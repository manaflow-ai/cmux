public import Foundation

/// A tab that can load a page whose TLS certificate the system does not
/// trust, after the user chose Proceed on the interstitial (WebKit; the
/// Chromium engine shows its own interstitial).
public protocol BrowserCertificateBypassing: AnyObject {
    /// Trusts the failing page's host for this browser profile until the
    /// app quits, and loads the page again.
    func proceedPastCertificateError()
}
