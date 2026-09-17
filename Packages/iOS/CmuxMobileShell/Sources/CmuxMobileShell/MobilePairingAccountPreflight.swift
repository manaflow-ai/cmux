internal import CMUXMobileCore
import Foundation

/// Account-binding preflight for a scanned/pasted pairing code.
///
/// Decides, before any route is dialed, whether the ticket's owner identity can
/// belong to the signed-in user. The value stores the live phone-side identity
/// and the scanned URL's declared scheme; tests can construct it directly
/// without standing up the full ``MobileShellComposite`` store.
struct MobilePairingAccountPreflight: Sendable {
    /// The scanned/pasted URL scheme, which declares the Mac's channel.
    let scannedScheme: String?
    /// The current phone-side Stack user id.
    let actualUserID: String?
    /// The current phone-side account email.
    let actualEmail: String?
    /// Whether ``actualUserID`` belongs to the development Stack project.
    let isDevelopmentAuthEnvironment: Bool

    /// Returns the account-related failure to show, or `nil` when preflight
    /// should stay silent and let the host-side verification own rejection.
    ///
    /// Precedence mirrors the QR grammar (#6028): when the ticket carries the
    /// opaque Stack user id binding (`ub`), that id must equal the phone's; the
    /// email is never consulted, so a QR cannot be softened by stamping a
    /// matching email next to a foreign id. Legacy tickets without `ub` fall
    /// back to the email comparison. Unknown local identity (signed out or
    /// still restoring) returns `nil`.
    ///
    /// A user-id mismatch is explained as
    /// ``MobilePairingFailureCategory/authEnvironmentMismatch(macChannelIsRelease:)``
    /// only when the two auth channels are declared to differ. The emitting Mac
    /// stamps its channel into the pairing URL's scheme (release Macs emit
    /// ``CmxPairingURLScheme/release``, dev Macs
    /// ``CmxPairingURLScheme/development``; #6038), so `scannedScheme` is an
    /// explicit Mac-side signal. Same-channel and unknown-scheme mismatches
    /// keep ``MobilePairingFailureCategory/authFailed``.
    func failure(for ticket: CmxAttachTicket) -> MobilePairingFailureCategory? {
        if let expectedUserID = normalizedNonEmpty(ticket.macUserID) {
            guard let actualUserID = normalizedNonEmpty(actualUserID) else {
                return nil
            }
            guard actualUserID == expectedUserID else {
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
        guard let actual = normalizedEmail(actualEmail) else { return nil }
        if let expected = normalizedEmail(ticket.macUserEmail) {
            guard actual == expected else {
                return .emailMismatch(expected: expected, actual: actual)
            }
            return nil
        }
        return nil
    }

    private var macDeclaresRelease: Bool {
        scannedScheme.map {
            CmxPairingURLScheme.release.caseInsensitiveCompare($0) == .orderedSame
        } ?? false
    }

    private var macDeclaresDevelopment: Bool {
        scannedScheme.map {
            CmxPairingURLScheme.development.caseInsensitiveCompare($0) == .orderedSame
        } ?? false
    }

    private func normalizedEmail(_ value: String?) -> String? {
        normalizedNonEmpty(value)?.lowercased()
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
