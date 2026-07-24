import Foundation

/// TTL- and LRU-bounded authorization snapshots for chunked workspace-changes reads.
actor WorkspaceChangesAuthorizedPathCache {
    struct Snapshot: Sendable {
        let repoRoot: String
        let currentPaths: Set<String>
        let basePaths: Set<String>
    }

    private struct Entry: Sendable {
        let snapshot: Snapshot
        let expiresAt: Date
        var lastAccessOrder: UInt64
    }

    private let timeToLive: TimeInterval
    private let maximumEntryCount: Int
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var accessOrder: UInt64 = 0

    init(
        timeToLive: TimeInterval = 15,
        maximumEntryCount: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.timeToLive = timeToLive
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.now = now
    }

    func snapshot(forRepoRoot repoRoot: String) -> Snapshot? {
        let currentTime = now()
        guard var entry = entries[repoRoot] else { return nil }
        guard entry.expiresAt > currentTime else {
            entries[repoRoot] = nil
            return nil
        }
        entry.lastAccessOrder = claimAccessOrder()
        entries[repoRoot] = entry
        return entry.snapshot
    }

    func store(_ snapshot: Snapshot) {
        let currentTime = now()
        entries = entries.filter { $0.value.expiresAt > currentTime }
        entries[snapshot.repoRoot] = Entry(
            snapshot: snapshot,
            expiresAt: currentTime.addingTimeInterval(timeToLive),
            lastAccessOrder: claimAccessOrder()
        )
        evictLeastRecentlyUsedEntries()
    }

    func entryCount() -> Int {
        entries.count
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
