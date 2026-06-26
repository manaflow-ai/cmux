import Foundation

/// Bounded cache of tracked-change scans keyed by repository, index stat, and
/// caller-owned filesystem-event generation.
actor GitTrackedChangesSnapshotCache {
    private struct CacheKey: Equatable, Hashable, Sendable {
        let repository: RepositoryKey
        let indexStatSignature: GitIndexStatSignature
        let trackedPathEventGeneration: UInt64

        init(
            repository: ResolvedGitRepository,
            indexStatSignature: GitIndexStatSignature,
            trackedPathEventGeneration: UInt64
        ) {
            self.repository = RepositoryKey(repository: repository)
            self.indexStatSignature = indexStatSignature
            self.trackedPathEventGeneration = trackedPathEventGeneration
        }
    }

    private struct RepositoryKey: Equatable, Hashable, Sendable {
        let workTreeRoot: String
        let gitDirectory: String

        init(repository: ResolvedGitRepository) {
            self.workTreeRoot = repository.workTreeRoot
            self.gitDirectory = repository.gitDirectory
        }
    }

    private struct Entry: Sendable {
        let snapshot: GitTrackedChangesSnapshot
    }

    private let maximumEntryCount: Int
    private var entriesByKey: [CacheKey: Entry] = [:]
    private var insertionOrder: [CacheKey] = []

    init(maximumEntryCount: Int = 256) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func snapshot(
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        trackedPathEventGeneration: UInt64
    ) -> GitTrackedChangesSnapshot? {
        let key = CacheKey(
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
        trackedPathEventGeneration: UInt64
    ) {
        let key = CacheKey(
            repository: repository,
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
        insertionOrder.removeAll { $0 == key }
        insertionOrder.append(key)
        entriesByKey[key] = Entry(snapshot: snapshot)
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
