import Foundation

/// Account-scoped authority for server-directed automatic reconnect delays.
///
/// This state is intentionally process-local. A broker Retry-After response is
/// short-lived transport control state, not durable user configuration.
struct MobileAutomaticReconnectBackoffOwner {
    private(set) var accountID: String?
    private(set) var retryAt: Date?

    mutating func record(
        accountID: String,
        retryAfterSeconds: Int,
        now: Date
    ) -> Date {
        let authoritativeSeconds = max(1, retryAfterSeconds)
        let proposedRetryAt = now.addingTimeInterval(TimeInterval(authoritativeSeconds))
        if self.accountID == accountID,
           let retryAt,
           retryAt >= proposedRetryAt {
            return retryAt
        }
        self.accountID = accountID
        retryAt = proposedRetryAt
        return proposedRetryAt
    }

    mutating func isBlocked(accountID: String, now: Date) -> Bool {
        guard self.accountID == accountID, let retryAt else { return false }
        guard retryAt > now else {
            clear(accountID: accountID)
            return false
        }
        return true
    }

    mutating func clear(accountID: String? = nil) {
        guard accountID == nil || self.accountID == accountID else { return }
        self.accountID = nil
        retryAt = nil
    }
}
