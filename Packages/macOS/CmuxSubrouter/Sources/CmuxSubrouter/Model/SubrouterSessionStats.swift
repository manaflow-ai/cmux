public import Foundation

/// Aggregations over the daemon's session-assignment history for the
/// panel's activity stats.
public enum SubrouterSessionStats {
    /// One account's routing activity within the window.
    public struct AccountActivity: Sendable, Equatable, Identifiable {
        public var id: String { accountID }

        /// The pinned account id (email or profile name).
        public let accountID: String
        /// Sessions routed to the account within the window.
        public let sessionCount: Int
        /// The most recent routing time.
        public let lastRoutedAt: Date

        /// Creates an activity row.
        public init(accountID: String, sessionCount: Int, lastRoutedAt: Date) {
            self.accountID = accountID
            self.sessionCount = sessionCount
            self.lastRoutedAt = lastRoutedAt
        }
    }

    /// Per-account session counts within `window` of `now`, most active
    /// first (ties broken by recency, then id for stability).
    public static func accountActivity(
        sessions: [SubrouterSessionAssignment],
        window: TimeInterval,
        now: Date
    ) -> [AccountActivity] {
        let cutoff = now.addingTimeInterval(-window)
        var countByAccount: [String: Int] = [:]
        var latestByAccount: [String: Date] = [:]
        for session in sessions where session.updatedAt >= cutoff {
            countByAccount[session.accountID, default: 0] += 1
            let existing = latestByAccount[session.accountID]
            if existing == nil || session.updatedAt > existing! {
                latestByAccount[session.accountID] = session.updatedAt
            }
        }
        return countByAccount
            .map { accountID, count in
                AccountActivity(
                    accountID: accountID,
                    sessionCount: count,
                    lastRoutedAt: latestByAccount[accountID] ?? cutoff
                )
            }
            .sorted {
                if $0.sessionCount != $1.sessionCount { return $0.sessionCount > $1.sessionCount }
                if $0.lastRoutedAt != $1.lastRoutedAt { return $0.lastRoutedAt > $1.lastRoutedAt }
                return $0.accountID < $1.accountID
            }
    }
}
