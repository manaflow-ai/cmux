import Foundation

/// Bounded cache of tracked-change scans keyed by repository, index stat, and
/// caller-owned filesystem-event generation.
actor GitTrackedChangesSnapshotCache {
    private struct RepositoryKey: Equatable, Hashable, Sendable {
        let workTreeRoot: String
        let gitDirectory: String

        init(repository: ResolvedGitRepository) {
            self.workTreeRoot = repository.workTreeRoot
            self.gitDirectory = repository.gitDirectory
        }
    }

    private struct Entry: Sendable {
        let indexStatSignature: GitIndexStatSignature
        let trackedPathEventGeneration: UInt64
        let snapshot: GitTrackedChangesSnapshot
    }

    private let maximumEntryCount: Int
    private var entriesByRepository: [RepositoryKey: Entry] = [:]
    private var insertionOrder: [RepositoryKey] = []

    init(maximumEntryCount: Int = 256) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func snapshot(
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        trackedPathEventGeneration: UInt64
    ) -> GitTrackedChangesSnapshot? {
        let key = RepositoryKey(repository: repository)
        guard let entry = entriesByRepository[key],
              entry.indexStatSignature == indexStatSignature,
              entry.trackedPathEventGeneration == trackedPathEventGeneration else {
            return nil
        }
        return entry.snapshot
    }

    func store(
        _ snapshot: GitTrackedChangesSnapshot,
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        trackedPathEventGeneration: UInt64
    ) {
        let key = RepositoryKey(repository: repository)
        if entriesByRepository[key] == nil {
            insertionOrder.append(key)
        }
        entriesByRepository[key] = Entry(
            indexStatSignature: indexStatSignature,
            trackedPathEventGeneration: trackedPathEventGeneration,
            snapshot: snapshot
        )
        evictOldestEntriesIfNeeded()
    }

    private func evictOldestEntriesIfNeeded() {
        while entriesByRepository.count > maximumEntryCount,
              let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entriesByRepository.removeValue(forKey: oldest)
        }
    }
}
