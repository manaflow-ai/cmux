import Foundation

/// A short-TTL, LRU-bounded cache of loaded change snapshots keyed by
/// workspace directory, so per-file diff requests (the pager mounts the
/// selected page and its neighbors) reuse one repository walk instead of
/// re-running whole-tree git commands per page turn. Freshness matches the
/// 15-second contract used by the summary and authorization caches.
actor WorkspaceChangesLoadedSnapshotCache {
    private struct Entry: Sendable {
        let scope: WorkspaceChangesScope
        let snapshot: WorkspaceChangesSnapshot
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
        maximumEntryCount: Int = 16,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.timeToLive = timeToLive
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.now = now
    }

    func loaded(forDirectory directory: String) -> (scope: WorkspaceChangesScope, snapshot: WorkspaceChangesSnapshot)? {
        let currentTime = now()
        entries = entries.filter { $0.value.expiresAt > currentTime }
        guard var entry = entries[directory] else { return nil }
        accessOrder &+= 1
        entry.lastAccessOrder = accessOrder
        entries[directory] = entry
        return (entry.scope, entry.snapshot)
    }

    func store(
        scope: WorkspaceChangesScope,
        snapshot: WorkspaceChangesSnapshot,
        forDirectory directory: String
    ) {
        let currentTime = now()
        entries = entries.filter { $0.value.expiresAt > currentTime }
        accessOrder &+= 1
        entries[directory] = Entry(
            scope: scope,
            snapshot: snapshot,
            expiresAt: currentTime.addingTimeInterval(timeToLive),
            lastAccessOrder: accessOrder
        )
        while entries.count > maximumEntryCount,
              let victim = entries.min(by: {
                  $0.value.lastAccessOrder < $1.value.lastAccessOrder
              }) {
            entries.removeValue(forKey: victim.key)
        }
    }

    func entryCount() -> Int {
        entries.count
    }
}
