import Foundation

/// TTL- and LRU-bounded authorized file locations for chunked workspace-changes reads.
actor WorkspaceChangesAuthorizedPathCache {
    struct Key: Hashable, Sendable {
        let directory: String
        let path: String
        let revision: WorkspaceChangesFileRevision
    }

    struct Snapshot: Sendable {
        let identity: UUID
        let scope: WorkspaceChangesScope
        let currentPaths: Set<String>
        let basePaths: Set<String>
    }

    struct AuthorizedFile: Sendable {
        let snapshot: Snapshot
        let relativePath: String
        let baseBlobSize: Int64?
        let baseBlobOID: String?
    }

    private struct Entry: Sendable {
        let authorizedFile: AuthorizedFile
        let expiresAt: Date
        var lastAccessOrder: UInt64
        var awaitsInitialFetch: Bool
    }

    private let timeToLive: TimeInterval
    private let maximumEntryCount: Int
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
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

    func authorizedFileForFetch(key: Key, offset: Int64) -> AuthorizedFile? {
        let currentTime = now()
        purgeExpiredEntries(at: currentTime)
        guard var entry = entries[key] else { return nil }
        if offset == 0, !entry.awaitsInitialFetch {
            entries[key] = nil
            return nil
        }
        if offset == 0 {
            entry.awaitsInitialFetch = false
        }
        entry.lastAccessOrder = claimAccessOrder()
        entries[key] = entry
        return entry.authorizedFile
    }

    func snapshot(
        forRepoRoot repoRoot: String,
        baseCommitOID: String
    ) -> Snapshot? {
        let currentTime = now()
        purgeExpiredEntries(at: currentTime)
        guard let matchKey = entries
            .filter({
                $0.value.authorizedFile.snapshot.scope.repoRoot == repoRoot
                    && $0.value.authorizedFile.snapshot.scope.diffBaseCommitOID == baseCommitOID
            })
            .max(by: { $0.value.lastAccessOrder < $1.value.lastAccessOrder })?
            .key,
            var match = entries[matchKey] else {
            return nil
        }
        match.lastAccessOrder = claimAccessOrder()
        entries[matchKey] = match
        return match.authorizedFile.snapshot
    }

    func store(
        _ authorizedFile: AuthorizedFile,
        for key: Key,
        awaitsInitialFetch: Bool
    ) {
        let currentTime = now()
        purgeExpiredEntries(at: currentTime)
        entries[key] = Entry(
            authorizedFile: authorizedFile,
            expiresAt: currentTime.addingTimeInterval(timeToLive),
            lastAccessOrder: claimAccessOrder(),
            awaitsInitialFetch: awaitsInitialFetch
        )
        evictLeastRecentlyUsedEntries()
    }

    func entryCount() -> Int {
        entries.count
    }

    private func purgeExpiredEntries(at currentTime: Date) {
        entries = entries.filter { $0.value.expiresAt > currentTime }
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
