import CmuxIrohTransport
public import Foundation

/// One endpoint-bound relay credential (EdDSA JWT, ~300s TTL). The relay
/// closes authenticated connections at the credential's signed expiry, so the
/// ONLY safe lifecycle is: refresh early, rotate with insertRelay alone
/// (make-before-break), and never let a live endpoint hold an expired token.
public struct IrxRelayCredential: Codable, Equatable, Sendable {
    /// The trusted relay origin associated with this credential.
    public var relayURL: String
    /// The short-lived signed relay token.
    public var token: String
    /// The token's signed expiration time.
    public var expiresAt: Date
    /// Server-suggested refresh time (typically expiry minus 60s).
    public var refreshAfter: Date

    /// Creates an endpoint-bound relay credential.
    public init(relayURL: String, token: String, expiresAt: Date, refreshAfter: Date) {
        self.relayURL = relayURL
        self.token = token
        self.expiresAt = expiresAt
        self.refreshAfter = refreshAfter
    }

    /// Returns whether the token remains usable after the requested margin.
    public func isUsable(at now: Date, margin: TimeInterval = 10) -> Bool {
        expiresAt.timeIntervalSince(now) > margin
    }
}

/// Pure refresh-policy decisions, unit-testable without clocks or network.
public struct IrxRelayCredentialPolicy: Equatable, Sendable {
    /// Creates a stateless relay-credential policy.
    public init() {}

    /// Refresh at min(server refreshAfter, expiry - 120s): earlier than the
    /// legacy stack's expiry-60s so one slow broker call or a short suspension
    /// never eats the entire margin. Jitter (0..10s, caller-supplied) prevents
    /// synchronized fleets.
    public func refreshDate(
        for credential: IrxRelayCredential,
        jitter: TimeInterval
    ) -> Date {
        let early = credential.expiresAt.addingTimeInterval(-120)
        let base = min(credential.refreshAfter, early)
        return base.addingTimeInterval(-max(0, min(jitter, 10)))
    }

    /// On mint failure, retry at half the remaining validity (floor 1s), so
    /// retries accelerate as expiry approaches instead of backing off past it.
    public func retryDelay(
        expiresAt: Date,
        now: Date
    ) -> Duration {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 2 else { return .seconds(1) }
        return .seconds(remaining / 2)
    }

    /// Combines expiry acceleration with the lifecycle retry policy while
    /// preserving a broker-provided `Retry-After` floor.
    ///
    /// The policy delay is bounded by the caller's retry schedule. A validated
    /// server floor may exceed that local cap, and is applied after expiry
    /// acceleration so a nearly expired credential cannot cause a
    /// rate-limited broker to be contacted early. Already-expired credentials
    /// use the one-second policy floor on the first failure; subsequent
    /// failures return to the exponential ladder so an outage cannot become a
    /// one-second poll.
    public func boundedRetryDelay(
        expiresAt: Date?,
        now: Date,
        policyDelay: TimeInterval,
        retryAfterSeconds: Int?,
        failureCount: Int = 0
    ) -> TimeInterval {
        let boundedPolicyDelay = max(0, policyDelay)
        let remainingValidity = expiresAt?.timeIntervalSince(now)
        let expiryDelay = expiresAt.map { expiryDate -> TimeInterval in
            let duration = retryDelay(expiresAt: expiryDate, now: now)
            let components = duration.components
            return TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        }
        let shouldBackOffPastExpiry = (remainingValidity ?? 0) <= 2
            && failureCount > 0
        let acceleratedDelay = shouldBackOffPastExpiry
            ? boundedPolicyDelay
            : min(expiryDelay ?? boundedPolicyDelay, boundedPolicyDelay)
        guard let retryAfterSeconds else { return acceleratedDelay }
        let serverFloor = min(
            TimeInterval(CmxIrohBrokerCooldown.maximumRetryAfterSeconds),
            TimeInterval(max(1, retryAfterSeconds))
        )
        return max(acceleratedDelay, serverFloor)
    }
}

/// Snapshot persisted to disk: credentials survive relaunch so a fresh app
/// start can bind its endpoint and dial with ZERO broker calls (steady-state
/// independence, the fast-launch requirement).
public struct IrxRelayCredentialSnapshot: Codable, Equatable, Sendable {
    /// The relay credentials retained for the endpoint.
    public var credentials: [IrxRelayCredential]
    /// Time at which the credential set was minted.
    public var mintedAt: Date
    /// The endpoint the tokens are bound to. The relay SILENTLY refuses a
    /// wrong-key token (the link just never comes up), so a cached snapshot
    /// from a different identity must never be reused.
    public var endpointIDHex: String?

    /// Creates a persisted relay-credential snapshot.
    public init(
        credentials: [IrxRelayCredential],
        mintedAt: Date,
        endpointIDHex: String? = nil
    ) {
        self.credentials = credentials
        self.mintedAt = mintedAt
        self.endpointIDHex = endpointIDHex
    }

    /// Returns only credentials with the configured safety margin remaining.
    public func usable(at now: Date) -> [IrxRelayCredential] {
        credentials.filter { $0.isUsable(at: now) }
    }
}
