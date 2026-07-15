public import Foundation

/// A short-lived 6-digit Mac-to-Mac pairing code advertised through the team
/// device registry.
///
/// The host Mac publishes the code (and its expiry) as instance labels on its
/// own `/api/devices` registration; another Mac claims it by typing the code,
/// matching it against the registry rows it can already see, and pairing with
/// the matching instance's advertised routes. The code is a rendezvous
/// selector, not a bearer secret: registry rows (including routes) are already
/// team-visible, and the pairing RPC still enforces account identity.
///
/// ```swift
/// let minted = CmxPairingCode(code: "042117", expiresAt: expiry)
/// body["instanceLabels"] = minted.instanceLabels
/// // …on the claiming Mac:
/// let active = CmxPairingCode.active(in: instance.labels, now: Date())
/// ```
public struct CmxPairingCode: Equatable, Sendable {
    /// Instance label carrying the 6-digit code.
    public static let codeLabelKey = "pairing_code"
    /// Instance label carrying the code's ISO 8601 expiry timestamp.
    public static let expiresAtLabelKey = "pairing_code_expires_at"

    /// The 6-digit, zero-padded code the user reads off the host Mac.
    public var code: String
    /// When the code stops being claimable.
    public var expiresAt: Date

    /// Creates a pairing code value.
    /// - Parameters:
    ///   - code: The 6-digit, zero-padded code string.
    ///   - expiresAt: When the code stops being claimable.
    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }

    /// Generates a fresh 6-digit code (zero-padded, `000000`–`999999`)
    /// expiring `ttl` from `now`.
    ///
    /// - Parameters:
    ///   - ttl: Code lifetime.
    ///   - now: Mint-side clock, injected for testability.
    ///   - generator: Randomness source, injected for testability.
    /// - Returns: The minted code value.
    public static func minted(
        ttl: TimeInterval,
        now: Date,
        using generator: inout some RandomNumberGenerator
    ) -> CmxPairingCode {
        CmxPairingCode(
            code: String(format: "%06d", Int.random(in: 0...999_999, using: &generator)),
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    /// The wire form: the instance labels a registration POST advertises.
    public var instanceLabels: [String: String] {
        [
            Self.codeLabelKey: code,
            Self.expiresAtLabelKey: Self.iso8601.string(from: expiresAt),
        ]
    }

    /// Decodes an unexpired pairing code from registry instance labels.
    ///
    /// A missing or unparseable expiry yields `nil` — a claim must never
    /// succeed against a code whose lifetime cannot be verified.
    ///
    /// - Parameters:
    ///   - labels: The instance's string labels as returned by the registry.
    ///   - now: The claim-side clock, injected for testability.
    /// - Returns: The active code, or `nil` when absent or expired.
    public static func active(in labels: [String: String], now: Date) -> CmxPairingCode? {
        guard
            let code = labels[codeLabelKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !code.isEmpty,
            let rawExpiry = labels[expiresAtLabelKey],
            let expiresAt = parseISO8601(rawExpiry),
            expiresAt > now
        else { return nil }
        return CmxPairingCode(code: code, expiresAt: expiresAt)
    }

    /// The user-typed claim input normalized for matching: digits only, so
    /// `"042 117"` and `"042117"` claim the same code.
    /// - Parameter rawInput: The text the user typed.
    /// - Returns: The digit string, or `nil` unless exactly 6 digits remain.
    public static func normalizedClaimInput(_ rawInput: String) -> String? {
        let digits = rawInput.filter(\.isNumber)
        return digits.count == 6 ? digits : nil
    }

    /// Encoder for the expiry label; fractional seconds match the registry's
    /// own `toISOString()` timestamps.
    private static var iso8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// Lenient ISO 8601 parse (fractional and whole-second forms). Formatters
    /// are created per call so the type stays `Sendable`-clean; this runs only
    /// on label reads, never in a hot path.
    private static func parseISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: trimmed)
    }
}
