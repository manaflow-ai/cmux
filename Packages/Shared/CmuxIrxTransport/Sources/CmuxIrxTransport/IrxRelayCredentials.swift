public import Foundation

/// One endpoint-bound relay credential (EdDSA JWT, ~300s TTL). The relay
/// closes authenticated connections at the credential's signed expiry, so the
/// ONLY safe lifecycle is: refresh early, rotate with insertRelay alone
/// (make-before-break), and never let a live endpoint hold an expired token.
public struct IrxRelayCredential: Codable, Equatable, Sendable {
    public var relayURL: String
    public var token: String
    public var expiresAt: Date
    /// Server-suggested refresh time (typically expiry minus 60s).
    public var refreshAfter: Date

    public init(relayURL: String, token: String, expiresAt: Date, refreshAfter: Date) {
        self.relayURL = relayURL
        self.token = token
        self.expiresAt = expiresAt
        self.refreshAfter = refreshAfter
    }

    public func isUsable(at now: Date, margin: TimeInterval = 10) -> Bool {
        expiresAt.timeIntervalSince(now) > margin
    }
}

/// Pure refresh-policy decisions, unit-testable without clocks or network.
public enum IrxRelayCredentialPolicy {
    /// Refresh at min(server refreshAfter, expiry - 120s): earlier than the
    /// legacy stack's expiry-60s so one slow broker call or a short suspension
    /// never eats the entire margin. Jitter (0..10s, caller-supplied) prevents
    /// synchronized fleets.
    public static func refreshDate(
        for credential: IrxRelayCredential,
        jitter: TimeInterval
    ) -> Date {
        let early = credential.expiresAt.addingTimeInterval(-120)
        let base = min(credential.refreshAfter, early)
        return base.addingTimeInterval(-max(0, min(jitter, 10)))
    }

    /// On mint failure, retry at half the remaining validity (floor 1s), so
    /// retries accelerate as expiry approaches instead of backing off past it.
    public static func retryDelay(
        expiresAt: Date,
        now: Date
    ) -> Duration {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 2 else { return .seconds(1) }
        return .seconds(remaining / 2)
    }
}

/// Snapshot persisted to disk: credentials survive relaunch so a fresh app
/// start can bind its endpoint and dial with ZERO broker calls (steady-state
/// independence, the fast-launch requirement).
public struct IrxRelayCredentialSnapshot: Codable, Equatable, Sendable {
    public var credentials: [IrxRelayCredential]
    public var mintedAt: Date
    /// The endpoint the tokens are bound to. The relay SILENTLY refuses a
    /// wrong-key token (the link just never comes up), so a cached snapshot
    /// from a different identity must never be reused.
    public var endpointIDHex: String?

    public init(
        credentials: [IrxRelayCredential],
        mintedAt: Date,
        endpointIDHex: String? = nil
    ) {
        self.credentials = credentials
        self.mintedAt = mintedAt
        self.endpointIDHex = endpointIDHex
    }

    public func usable(at now: Date) -> [IrxRelayCredential] {
        credentials.filter { $0.isUsable(at: now) }
    }
}
