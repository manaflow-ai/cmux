import Foundation

/// Page Info's "Turn on warnings" on Chromium. Chromium shows its own
/// certificate interstitial and keeps the user's Proceed choices in its
/// profile (`SSLHostStateDelegate`).
extension CEFTab: BrowserCertificateWarningRevoking {
    public var certificateWarningsTurnedOff: Bool { false }

    public func turnOnCertificateWarnings() async -> Bool { false }
}
