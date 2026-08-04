import Foundation

/// A TTL- and LRU-bounded summary cache keyed by canonical repository root.
actor WorkspaceChangesSummaryCache {
    private struct Entry: Sendable {
        let summary: WorkspaceChangesSummary
        let storedAt: Duration
        var lastAccessOrder: UInt64
    }

    private let ttl: Duration
    private let maximumEntryCount: Int
    private let clock: any WorkspaceChangesClock
    private var entries: [String: Entry] = [:]
    private var accessOrder: UInt64 = 0

    init(
        ttl: Duration = .seconds(15),
        maximumEntryCount: Int = 64,
        clock: any WorkspaceChangesClock = SystemWorkspaceChangesClock()
    ) {
        self.ttl = ttl
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.clock = clock
    }

    func summary(forRepoRoot repoRoot: String) async -> WorkspaceChangesSummary? {
        // Take the clock reading first: the entry must be read AFTER the
        // suspension point, or a fresher entry stored mid-await could be
        // validated against (and evicted for) a stale pre-await copy.
        let now = await clock.now()
        purgeExpiredEntries(at: now)
        guard var entry = entries[repoRoot] else { return nil }
        entry.lastAccessOrder = claimAccessOrder()
        entries[repoRoot] = entry
        return entry.summary
    }

    func store(_ summary: WorkspaceChangesSummary, forRepoRoot repoRoot: String) async {
        let now = await clock.now()
        purgeExpiredEntries(at: now)
        entries[repoRoot] = Entry(
            summary: summary,
            storedAt: now,
            lastAccessOrder: claimAccessOrder()
        )
        evictLeastRecentlyUsedEntries()
    }

    func entryCount() -> Int {
        entries.count
    }

    private func purgeExpiredEntries(at now: Duration) {
        entries = entries.filter { now - $0.value.storedAt < ttl }
    }

    private func claimAccessOrder() -> UInt64 {
        defer { accessOrder &+= 1 }
        return accessOrder
    }

    private func evictLeastRecentlyUsedEntries() {
        while entries.count > maximumEntryCount,
              let leastRecentlyUsed = entries.min(by: {
                  $0.value.lastAccessOrder < $1.value.lastAccessOrder
              }) {
            entries.removeValue(forKey: leastRecentlyUsed.key)
        }
    }
}
