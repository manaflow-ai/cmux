public import Foundation

/// A Chromium page that can go past a certificate error on cmux's warning
/// page. That page shows only where Chromium shows no interstitial of its
/// own (an agent-driven tab), and its Proceed is native UI that only a
/// person can press; page script cannot.
@MainActor
public protocol BrowserPageCertificateBypassing: AnyObject {
    /// Answers the page's next certificate error at `url`'s host
    /// (``ChromiumNetError/certificateProceed(host:)``), then loads `url` again.
    /// - Returns: `false` when the page is gone or `url` has no host.
    @discardableResult
    func proceedPastCertificateError(_ error: ChromiumNetError, at url: URL) -> Bool
}
