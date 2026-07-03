internal import CMUXMobileCore
import Foundation

/// Account-binding preflight for a scanned/pasted pairing code.
///
/// Decides, before any route is dialed, whether the ticket's owner identity
/// belongs to the signed-in user. The value stores the live phone-side identity
/// so tests can construct it directly without standing up the full
/// ``MobileShellComposite`` store.
struct MobilePairingAccountPreflight: Sendable {
    /// The current phone-side Stack user id.
    let actualUserID: String?
    /// The current phone-side account email.
    let actualEmail: String?

    /// Returns the account-related failure to show, or `nil` when preflight
    /// should stay silent and let the host-side verification own rejection.
    ///
    /// Precedence mirrors the QR grammar (#6028): when the ticket carries the
    /// opaque Stack user id binding (`ub`), that id must equal the phone's; the
    /// email is never consulted, so a QR cannot be softened by stamping a
    /// matching email next to a foreign id. Legacy tickets without `ub` fall
    /// back to the email comparison. Unknown local identity (signed out or
    /// still restoring) returns `nil`.
    func failure(for ticket: CmxAttachTicket) -> MobilePairingFailureCategory? {
        if let expectedUserID = normalizedNonEmpty(ticket.macUserID) {
            guard let actualUserID = normalizedNonEmpty(actualUserID) else {
                return nil
            }
            guard actualUserID == expectedUserID else {
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

    private func normalizedEmail(_ value: String?) -> String? {
        normalizedNonEmpty(value)?.lowercased()
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
