internal import CMUXMobileCore
import Foundation

extension MobileShellComposite {
    /// The account-binding preflight for a scanned/pasted pairing code: decide,
    /// before any route is dialed, whether the ticket's owner identity can
    /// belong to the signed-in user. Pure and unit-tested; the call site only
    /// supplies the live identity and the scanned URL's scheme.
    ///
    /// Precedence mirrors the QR grammar (#6028): when the ticket carries the
    /// opaque Stack user id binding (`ub`), that id must equal the phone's —
    /// the email is never consulted, so a QR cannot be softened by stamping a
    /// matching email next to a foreign id. Legacy tickets without `ub` fall
    /// back to the email comparison. Unknown local identity (signed out or
    /// still restoring) returns `nil` and leaves rejection to the host's
    /// Stack-token verification.
    ///
    /// A user-id mismatch is explained as
    /// ``MobilePairingFailureCategory/authEnvironmentMismatch(macChannelIsRelease:)``
    /// only when the two auth channels are DECLARED to differ — never inferred
    /// from the phone alone. The emitting Mac stamps its channel into the
    /// pairing URL's scheme (release Macs emit ``CmxPairingURLScheme/release``,
    /// dev Macs ``CmxPairingURLScheme/development``; #6038), so `scannedScheme`
    /// is an explicit Mac-side signal, and Stack user ids are per-project so a
    /// cross-project binding can never match. Both directions are covered: a
    /// development-auth phone scanning a release-Mac QR (the sideloaded-dogfood
    /// bug, https://github.com/manaflow-ai/cmux/issues/7145) and a
    /// production-auth phone scanning a dev-Mac QR. Every same-channel or
    /// unknown-scheme mismatch keeps
    /// ``MobilePairingFailureCategory/authFailed``, so the #6028 binding and
    /// its copy are unchanged there.
    static func emailFailure(
        for ticket: CmxAttachTicket,
        scannedScheme: String?,
        actualUserID: String?,
        actualEmail: String?,
        isDevelopmentAuthEnvironment: Bool
    ) -> MobilePairingFailureCategory? {
        if let expectedUserID = Self.mobileShellNormalizedNonEmpty(ticket.macUserID) {
            guard let actualUserID = Self.mobileShellNormalizedNonEmpty(actualUserID) else { return nil }
            guard actualUserID == expectedUserID else {
                let macDeclaresRelease = scannedScheme.map {
                    CmxPairingURLScheme.release.caseInsensitiveCompare($0) == .orderedSame
                } ?? false
                let macDeclaresDevelopment = scannedScheme.map {
                    CmxPairingURLScheme.development.caseInsensitiveCompare($0) == .orderedSame
                } ?? false
                if isDevelopmentAuthEnvironment, macDeclaresRelease {
                    return .authEnvironmentMismatch(macChannelIsRelease: true)
                }
                if !isDevelopmentAuthEnvironment, macDeclaresDevelopment {
                    return .authEnvironmentMismatch(macChannelIsRelease: false)
                }
                return .authFailed
            }
            return nil
        }
        guard let actual = Self.mobileShellNormalizedEmail(actualEmail) else { return nil }
        if let expected = Self.mobileShellNormalizedEmail(ticket.macUserEmail) {
            guard actual == expected else {
                return .emailMismatch(expected: expected, actual: actual)
            }
            return nil
        }
        return nil
    }
}
