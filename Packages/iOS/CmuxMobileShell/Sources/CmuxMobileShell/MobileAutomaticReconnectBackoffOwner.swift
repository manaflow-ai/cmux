import Foundation

/// Account-scoped authority for server and transient reconnect delays.
///
/// This state is intentionally process-local. A broker Retry-After response is
/// short-lived transport control state, not durable user configuration.
struct MobileAutomaticReconnectBackoffOwner {
    private(set) var accountID: String?
    private(set) var serverRetryAt: Date?
    private(set) var transientRetryAt: Date?
    private(set) var transientFailureCount = 0

    var retryAt: Date? {
        switch (serverRetryAt, transientRetryAt) {
        case let (server?, transient?): max(server, transient)
        case let (server?, nil): server
        case let (nil, transient?): transient
        case (nil, nil): nil
        }
    }

    mutating func record(
        accountID: String,
        retryAfterSeconds: Int,
        now: Date
    ) -> Date {
        let authoritativeSeconds = max(1, retryAfterSeconds)
        let proposedRetryAt = now.addingTimeInterval(TimeInterval(authoritativeSeconds))
        prepare(accountID: accountID)
        if let serverRetryAt, serverRetryAt >= proposedRetryAt {
            return retryAt ?? serverRetryAt
        }
        serverRetryAt = proposedRetryAt
        return retryAt ?? proposedRetryAt
    }

    mutating func recordTransientFailure(accountID: String, now: Date) -> Date {
        prepare(accountID: accountID)
        if transientFailureCount < Int.max { transientFailureCount += 1 }
        let exponent = min(max(0, transientFailureCount - 1), 5)
        let delay = min(60, 2 * (1 << exponent))
        let proposedRetryAt = now.addingTimeInterval(TimeInterval(delay))
        transientRetryAt = proposedRetryAt
        return retryAt ?? proposedRetryAt
    }

    mutating func isBlocked(accountID: String, now: Date) -> Bool {
        guard self.accountID == accountID else { return false }
        if let serverRetryAt, serverRetryAt <= now { self.serverRetryAt = nil }
        if let transientRetryAt, transientRetryAt <= now { self.transientRetryAt = nil }
        return retryAt.map { $0 > now } ?? false
    }

    mutating func clearTransientCooldown(accountID: String) {
        guard self.accountID == accountID else { return }
        transientRetryAt = nil
    }

    mutating func clear(accountID: String? = nil) {
        guard accountID == nil || self.accountID == accountID else { return }
        self.accountID = nil
        serverRetryAt = nil
        transientRetryAt = nil
        transientFailureCount = 0
    }

    private mutating func prepare(accountID: String) {
        guard self.accountID != accountID else { return }
        clear()
        self.accountID = accountID
    }
}
