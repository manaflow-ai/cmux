import Foundation

/// Account-scoped broker rate-limit floors that OUTLIVE connection and runtime
/// teardown. The recorded failure: Retry-After was honored only within one
/// endpoint activation, every reconnect tore the runtime down and discarded
/// it, so each new activation re-hit the broker inside the server's window —
/// a self-sustaining retry storm ("endpointFailed b=255", phone never
/// reconnects). This ledger is held by the composition root, keyed by
/// account, and consulted before any broker mutation.
public actor PeerBrokerCooldownLedger {
    public struct Key: Sendable, Hashable {
        public let accountID: String

        public init(accountID: String) {
            self.accountID = accountID
        }
    }

    /// Default floor for a 429 with no Retry-After header.
    public static let headerlessFloor: Duration = .seconds(60)

    private var floors: [Key: ContinuousClock.Instant] = [:]
    private let clock: ContinuousClock

    public init(clock: ContinuousClock = ContinuousClock()) {
        self.clock = clock
    }

    /// Record a server floor. Overlapping floors keep the LATER deadline.
    public func noteRetryAfter(_ delay: Duration?, key: Key) {
        let effective = delay ?? Self.headerlessFloor
        let deadline = clock.now.advanced(by: effective)
        if let existing = floors[key], existing >= deadline {
            return
        }
        floors[key] = deadline
    }

    /// Remaining cooldown for the account, or nil when clear. While active,
    /// activation skips broker work entirely and surfaces the floor to the
    /// reconnect scheduler.
    public func activeCooldown(key: Key) -> Duration? {
        guard let deadline = floors[key] else { return nil }
        let now = clock.now
        guard deadline > now else {
            floors[key] = nil
            return nil
        }
        return now.duration(to: deadline)
    }

    public func clear(key: Key) {
        floors[key] = nil
    }
}
