import Foundation

/// Bounded cache of tracked-change scans keyed by repository, index stat, and
/// namespaced caller-owned filesystem-event generation.
actor GitTrackedChangesSnapshotCache {
    private let maximumEntryCount: Int
    private var entriesByKey: [
        GitTrackedChangesSnapshotCacheKey: GitTrackedChangesSnapshotCacheEntry
    ] = [:]
    private var insertionOrder: [GitTrackedChangesSnapshotCacheKey] = []

    init(maximumEntryCount: Int = 256) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func snapshot(
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        trackedPathEventGeneration: GitTrackedPathEventGeneration
    ) -> GitTrackedChangesSnapshot? {
        let key = GitTrackedChangesSnapshotCacheKey(
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
        return entriesByKey[key]?.snapshot
    }

    func store(
        _ snapshot: GitTrackedChangesSnapshot,
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        trackedPathEventGeneration: GitTrackedPathEventGeneration
    ) {
        let key = GitTrackedChangesSnapshotCacheKey(
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
        insertionOrder.removeAll { $0 == key }
        insertionOrder.append(key)
        entriesByKey[key] = GitTrackedChangesSnapshotCacheEntry(snapshot: snapshot)
        evictOldestEntriesIfNeeded()
    }

    private func evictOldestEntriesIfNeeded() {
        while entriesByKey.count > maximumEntryCount,
              let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entriesByKey.removeValue(forKey: oldest)
        }
    }
}
