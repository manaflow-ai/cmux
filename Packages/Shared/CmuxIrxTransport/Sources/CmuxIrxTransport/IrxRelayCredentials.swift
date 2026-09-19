public import CMUXMobileCore
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

    /// The first retry delay when there is no credential deadline to race.
    static let coldRetryFloor: TimeInterval = 5
    /// The largest retry delay this policy will ever produce.
    static let coldRetryCeiling: TimeInterval = 300

    /// How long to wait before minting again after a failure.
    ///
    /// Two regimes, because they answer different questions:
    ///
    /// - Credentials are live and expiring. There is a real deadline, so
    ///   retry at half the remaining validity: attempts accelerate toward
    ///   expiry rather than backing off past it.
    /// - Nothing usable is cached (first mint, or after a purge). There is no
    ///   deadline, so back off exponentially from ``coldRetryFloor``. The old
    ///   policy passed `now` as the expiry here, which made `remaining` zero
    ///   and pinned the retry at one second forever: a single wedged device
    ///   minted once a second indefinitely, and enough of them exhausted the
    ///   auth provider's project-wide rate limit for every other client.
    ///
    /// A server-supplied `Retry-After` is a floor in both regimes. Asking
    /// again before it elapses cannot succeed and only deepens the throttle.
    public static func retryDelay(
        expiresAt: Date?,
        now: Date,
        consecutiveFailures: Int,
        retryAfterSeconds: Int?,
        jitterUnitInterval: Double = Double.random(in: 0...1)
    ) -> Duration {
        let serverFloor = retryAfterSeconds.map { TimeInterval(max(0, $0)) } ?? 0
        let remaining = expiresAt.map { $0.timeIntervalSince(now) } ?? 0
        let base: TimeInterval
        if remaining > 2 {
            base = remaining / 2
        } else {
            // Zero-based: the first failure waits the floor, not double it.
            let steps = Double(min(max(0, consecutiveFailures - 1), 10))
            let exponential = coldRetryFloor * pow(2, steps)
            let bounded = min(coldRetryCeiling, exponential)
            let jitter = min(1, max(0, jitterUnitInterval))
            // Jitter above the floor only, so a fleet that failed together
            // does not retry together.
            base = bounded + bounded * 0.25 * jitter
        }
        return .seconds(max(base, serverFloor))
    }

    /// The retry floor the broker asked for, when the failure carried one.
    public static func retryAfterSeconds(for error: any Error) -> Int? {
        (error as? any CmxRetryAfterProviding)?.retryAfterSeconds
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
