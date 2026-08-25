import Foundation

/// How this endpoint earns admission at the relay fleet.
///
/// `.tokenMinting` is today's deployed contract (cmux-relay#8): every relay
/// connection presents an endpoint-bound JWT, the relay closes the socket at
/// the token's `exp`, and the client must re-mint before that deadline.
///
/// `.registryAllow` is the intended shape (cmux-relay#9 + web #10730): the
/// relay proves the endpoint key in its handshake and asks the broker's
/// allow hook whether that key is in the account registry. The client holds
/// no credential, mints nothing, and runs no renewal loop; revocation is a
/// registry flip plus a relay-side kick. Select it only once the fleet runs
/// the allow hook (dual-accept keeps `.tokenMinting` clients working during
/// the migration window).
public enum RelayCredentialMode: String, Sendable, Codable {
    case tokenMinting = "token_minting"
    case registryAllow = "registry_allow"

    /// Whether the client must mint and renew relay credentials in this mode.
    public var requiresClientCredential: Bool {
        switch self {
        case .tokenMinting: return true
        case .registryAllow: return false
        }
    }
}

/// Pure scheduling math for credential renewal, replacing fixed-interval
/// `Task.sleep(240s)` loops: the next refresh is derived from the earliest
/// actual `expiresAt` across the installed credentials, minus a lead, plus
/// caller-supplied jitter so a fleet of clients does not re-mint in
/// lockstep. Credentials without a parseable expiry fall back to the legacy
/// cadence so a shorter- or longer-lived token is honored either way.
public enum RelayCredentialSchedule {
    /// Seconds of validity we insist on having left when the refresh fires.
    public static let defaultLeadSeconds: Int64 = 60
    /// Cadence for credentials that carry no expiry (matches the deployed
    /// 300s TTL minus the default lead).
    public static let fallbackIntervalSeconds: Int64 = 240
    /// Never schedule tighter than this, so a clock-skewed or already-stale
    /// credential produces a prompt retry instead of a hot loop.
    public static let minimumDelaySeconds: Int64 = 10

    /// Epoch seconds at which the next renewal should run, or nil when
    /// nothing needs renewing (no credentials, or the mode holds none).
    ///
    /// - Parameters:
    ///   - expiries: `expiresAt` claims (epoch seconds) of the installed
    ///     credentials; nil entries mean "no expiry visible".
    ///   - now: current epoch seconds.
    ///   - leadSeconds: how long before the earliest expiry to fire.
    ///   - jitterSeconds: non-negative offset the caller draws at random;
    ///     it is applied *earlier* than the lead so jitter can never push a
    ///     refresh past expiry.
    public static func nextRefresh(
        expiries: [Int64?],
        now: Int64,
        leadSeconds: Int64 = defaultLeadSeconds,
        jitterSeconds: Int64 = 0
    ) -> Int64? {
        guard !expiries.isEmpty else { return nil }
        let earliest = expiries.compactMap { $0 }.min()
        let target: Int64
        if let earliest {
            target = earliest - leadSeconds - max(0, jitterSeconds)
        } else {
            target = now + fallbackIntervalSeconds - max(0, jitterSeconds)
        }
        return max(target, now + minimumDelaySeconds)
    }

    /// Convenience over broker credentials.
    public static func nextRefresh(
        credentials: [BrokerCredentialClient.Credential],
        now: Int64,
        leadSeconds: Int64 = defaultLeadSeconds,
        jitterSeconds: Int64 = 0
    ) -> Int64? {
        nextRefresh(
            expiries: credentials.map(\.expiresAt),
            now: now,
            leadSeconds: leadSeconds,
            jitterSeconds: jitterSeconds)
    }
}

/// Startup readiness of a next-transport host. The presence route and the
/// pairing ticket become visible only at `.published`: a host that is
/// advertised before its relay attach and address set are current invites
/// exactly the half-ready dial race of cmux#9724, so readiness is a gate,
/// not a hint.
public enum NextTransportReadiness: Int, Sendable, Comparable, CustomStringConvertible {
    /// Runtime object exists; endpoint not bound yet.
    case starting = 0
    /// Endpoint bound; direct paths may exist, relay not yet usable.
    case bound = 1
    /// Relay attach reported usable (or the host is deliberately
    /// direct-only and skips the relay leg).
    case relayAttached = 2
    /// Addresses current and the accept loop is live: the host may be
    /// advertised and its ticket handed out.
    case published = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .starting: return "starting"
        case .bound: return "bound"
        case .relayAttached: return "relay-attached"
        case .published: return "published"
        }
    }
}
