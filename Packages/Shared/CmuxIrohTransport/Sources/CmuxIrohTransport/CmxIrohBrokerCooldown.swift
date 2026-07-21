public import CMUXMobileCore
public import Foundation

/// Account-scoped cooldown honoring a broker's Retry-After directive across
/// endpoint activation attempts.
///
/// The credential coordinator already honors Retry-After inside one activation,
/// but a torn-down runtime discards that state, so every reconnect attempt
/// re-ran the full broker call set and kept the server's rate-limit window
/// exhausted. This value survives between activations: while active, callers
/// skip broker work entirely and surface the remaining delay to the reconnect
/// scheduler.
public struct CmxIrohBrokerCooldown: Equatable, Sendable {
    public private(set) var accountID: String?
    public private(set) var retryAt: Date?

    public init() {}

    /// Records a server directive, keeping the later of two overlapping floors.
    /// A directive for a different account replaces the previous floor.
    @discardableResult
    public mutating func record(
        accountID: String,
        retryAfterSeconds: Int,
        now: Date
    ) -> Date {
        let proposed = now.addingTimeInterval(TimeInterval(max(1, retryAfterSeconds)))
        if self.accountID != accountID {
            self.accountID = accountID
            retryAt = proposed
            return proposed
        }
        if let retryAt, retryAt >= proposed { return retryAt }
        retryAt = proposed
        return proposed
    }

    /// Whole seconds until the floor expires, or `nil` when no floor applies.
    /// Expired floors are cleared on read so state cannot go stale.
    public mutating func remainingSeconds(accountID: String, now: Date) -> Int? {
        guard self.accountID == accountID, let retryAt else { return nil }
        let remaining = retryAt.timeIntervalSince(now)
        guard remaining > 0 else {
            clear()
            return nil
        }
        return Int(remaining.rounded(.up))
    }

    /// Clears the floor, optionally only when it belongs to one account.
    public mutating func clear(accountID: String? = nil) {
        guard accountID == nil || self.accountID == accountID else { return }
        self.accountID = nil
        retryAt = nil
    }
}

/// Thrown instead of a bare inactive-runtime error while a broker cooldown is
/// active, so the reconnect scheduler can adopt the server's floor instead of
/// its short transient backoff.
public struct CmxIrohBrokerCooldownError: CmxRetryAfterProviding, Equatable {
    public let retryAfterSeconds: Int?

    public init(retryAfterSeconds: Int) {
        self.retryAfterSeconds = max(1, retryAfterSeconds)
    }
}

extension CmxIrohBrokerCooldownError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind { .policyUnavailable }
}
