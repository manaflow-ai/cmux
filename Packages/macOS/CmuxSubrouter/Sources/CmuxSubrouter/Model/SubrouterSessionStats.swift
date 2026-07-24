public import Foundation

/// Aggregations over the daemon's session-assignment history for the
/// panel's activity stats.
public enum SubrouterSessionStats {
    /// One account's routing activity within the window.
    public struct AccountActivity: Sendable, Equatable, Identifiable {
        /// Provider-scoped: a Codex email and a Claude profile name can be
        /// the same string, so identity needs the agent type too.
        public var id: String { "\(agentType)\u{1F}\(accountID)" }

        /// The daemon's agent type for the routed sessions (e.g. `codex`).
        public let agentType: String
        /// The pinned account id (email or profile name).
        public let accountID: String
        /// Sessions routed to the account within the window.
        public let sessionCount: Int
        /// The most recent routing time.
        public let lastRoutedAt: Date

        /// Creates an activity row.
        public init(agentType: String, accountID: String, sessionCount: Int, lastRoutedAt: Date) {
            self.agentType = agentType
            self.accountID = accountID
            self.sessionCount = sessionCount
            self.lastRoutedAt = lastRoutedAt
        }
    }

    /// Per-account session counts within `window` of `now`, most active
    /// first (ties broken by recency, then id for stability). Accounts are
    /// keyed by `(agentType, accountID)` — the same rule as
    /// ``SubrouterUsageHistory`` keys — so cross-provider accounts sharing
    /// one id never merge into a single row.
    public static func accountActivity(
        sessions: [SubrouterSessionAssignment],
        window: TimeInterval,
        now: Date
    ) -> [AccountActivity] {
        struct Key: Hashable {
            let agentType: String
            let accountID: String
        }
        let cutoff = now.addingTimeInterval(-window)
        var countByAccount: [Key: Int] = [:]
        var latestByAccount: [Key: Date] = [:]
        for session in sessions where session.updatedAt >= cutoff {
            let key = Key(agentType: session.agentType, accountID: session.accountID)
            countByAccount[key, default: 0] += 1
            let existing = latestByAccount[key]
            if existing == nil || session.updatedAt > existing! {
                latestByAccount[key] = session.updatedAt
            }
        }
        return countByAccount
            .map { key, count in
                AccountActivity(
                    agentType: key.agentType,
                    accountID: key.accountID,
                    sessionCount: count,
                    lastRoutedAt: latestByAccount[key] ?? cutoff
                )
            }
            .sorted {
                if $0.sessionCount != $1.sessionCount { return $0.sessionCount > $1.sessionCount }
                if $0.lastRoutedAt != $1.lastRoutedAt { return $0.lastRoutedAt > $1.lastRoutedAt }
                if $0.accountID != $1.accountID { return $0.accountID < $1.accountID }
                return $0.agentType < $1.agentType
            }
    }
}
