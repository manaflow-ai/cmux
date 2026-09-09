public import CMUXMobileCore
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
import Foundation

/// Decodes a pasted `cmux-ios://attach?…` pairing link (the same payload the
/// Mac's pairing window renders as a QR code) into an attach ticket a Mac can
/// pair from, applying the Mac-side trust policy.
///
/// A Mac has no camera, so link paste / manual entry is the macOS counterpart
/// of the phone's QR scan. The grammar and validation are shared with iOS via
/// `CmxAttachTicketInput`; this type adds the two Mac-side policies:
///
/// - **Loopback**: outside dev builds a link whose routes all point at
///   `127.0.0.1` would make this Mac dial itself, so it is rejected exactly
///   like a physical phone rejects it. Dev builds keep loopback so two tagged
///   builds on one machine can pair for dogfooding.
/// - **Account**: when the link carries the host's Stack user id and it
///   differs from this Mac's signed-in user, pairing is refused up front
///   (the host would reject every RPC with `account_mismatch` anyway).
public struct HivePairingLinkDecoder: Sendable {
    /// Whether loopback-only links are acceptable (dev builds testing two
    /// instances on one machine). Injected so the policy is testable in both
    /// positions from a single build configuration.
    public var allowsLoopbackRoutes: Bool

    /// Creates a decoder.
    /// - Parameter allowsLoopbackRoutes: Accept loopback routes (dev builds).
    public init(allowsLoopbackRoutes: Bool) {
        self.allowsLoopbackRoutes = allowsLoopbackRoutes
    }

    /// The decode result: a ticket, or the semantic failure the UI localizes.
    public enum Outcome: Sendable {
        /// The link decoded into a valid, policy-passing ticket.
        case ticket(CmxAttachTicket)
        /// The text is not a cmux pairing link or failed validation.
        case invalidLink
        /// Every dialable route pointed back at this computer.
        case loopbackRejected
        /// The link belongs to a different signed-in account.
        case accountMismatch
    }

    /// Decode and policy-check one pasted pairing link.
    ///
    /// - Parameters:
    ///   - rawValue: The pasted link text (whitespace is trimmed).
    ///   - currentStackUserID: This Mac's signed-in Stack user id, if any.
    /// - Returns: The decoded ticket or a semantic failure.
    public func decode(_ rawValue: String, currentStackUserID: String?) -> Outcome {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidLink }
        let ticket: CmxAttachTicket
        do {
            ticket = try CmxAttachTicketInput.decode(trimmed)
        } catch {
            if case MobileSyncPairingPayloadError.loopbackRouteRejected = error {
                return .loopbackRejected
            }
            return .invalidLink
        }
        if MobileShellRouteAuthPolicy.ticketRejectsLoopbackRoutes(
            ticket.routes,
            isPhysicalDevice: !allowsLoopbackRoutes
        ) {
            return .loopbackRejected
        }
        if let expected = normalizedNonEmpty(ticket.macUserID),
           let actual = normalizedNonEmpty(currentStackUserID),
           expected != actual {
            return .accountMismatch
        }
        return .ticket(ticket)
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
