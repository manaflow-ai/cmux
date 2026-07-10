import Foundation

/// Bounded cache of tracked-change scans keyed by repository, index stat, and
/// namespaced caller-owned filesystem-event generation. Sharing one instance
/// also coalesces concurrent cache misses for the same key into one scan.
public actor GitTrackedChangesSnapshotCache {
    private struct InFlightSnapshot {
        let id: UUID
        let task: Task<GitTrackedChangesSnapshot, Never>
    }

    private let maximumEntryCount: Int
    private var entriesByKey: [
        GitTrackedChangesSnapshotCacheKey: GitTrackedChangesSnapshotCacheEntry
    ] = [:]
    private var insertionOrder: [GitTrackedChangesSnapshotCacheKey] = []
    private var inFlightSnapshotsByKey: [
        GitTrackedChangesSnapshotCacheKey: InFlightSnapshot
    ] = [:]

    /// Creates an injectable tracked-snapshot coordination scope.
    ///
    /// - Parameter maximumEntryCount: Maximum completed snapshots retained.
    public init(maximumEntryCount: Int = 256) {
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

    func snapshot(
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        trackedPathEventGeneration: GitTrackedPathEventGeneration,
        load: @escaping @Sendable () -> GitTrackedChangesSnapshot
    ) async -> GitTrackedChangesSnapshot {
        let key = GitTrackedChangesSnapshotCacheKey(
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
        if let snapshot = entriesByKey[key]?.snapshot {
            return snapshot
        }

        let inFlightSnapshot: InFlightSnapshot
        if let existing = inFlightSnapshotsByKey[key] {
            inFlightSnapshot = existing
        } else {
            let id = UUID()
            let task = Task.detached(priority: Task.currentPriority) {
                load()
            }
            inFlightSnapshot = InFlightSnapshot(id: id, task: task)
            inFlightSnapshotsByKey[key] = inFlightSnapshot
        }

        let snapshot = await inFlightSnapshot.task.value
        if inFlightSnapshotsByKey[key]?.id == inFlightSnapshot.id {
            inFlightSnapshotsByKey.removeValue(forKey: key)
            store(snapshot, for: key)
        }
        return snapshot
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
        store(snapshot, for: key)
    }

    private func store(
        _ snapshot: GitTrackedChangesSnapshot,
        for key: GitTrackedChangesSnapshotCacheKey
    ) {
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
