import Foundation

/// Bounded process scope for repository revision authority and tracked scans.
///
/// Filesystem watchers advance a repository revision here before scheduling
/// work. Fallback requests carry the coordinator's explicit global round ID.
/// Snapshot loads use the stamped immutable authority after they pass through
/// the process limiter, so queued work cannot accidentally adopt a later round.
public actor GitTrackedChangesSnapshotScope {
    private struct RepositoryState {
        var epoch = UUID()
        var revision: UInt64 = 0
        var lastStableWatcherEventID: GitTrackedPathEventID?
        var stableWatcherEventIDsAreReliable = true
    }

    private let snapshotCache: GitTrackedChangesSnapshotCache
    private let maximumRepositoryCount: Int
    private var repositoryStates: [
        GitTrackedChangesRepositoryIdentity: RepositoryState
    ] = [:]
    private var repositoryInsertionOrder: [GitTrackedChangesRepositoryIdentity] = []

    /// Creates a bounded, injectable coordination scope.
    public init(
        maximumSnapshotCount: Int = 256,
        maximumRepositoryCount: Int = 256
    ) {
        self.snapshotCache = GitTrackedChangesSnapshotCache(
            maximumEntryCount: maximumSnapshotCount
        )
        self.maximumRepositoryCount = max(1, maximumRepositoryCount)
    }

    init(
        snapshotCache: GitTrackedChangesSnapshotCache,
        maximumRepositoryCount: Int = 256
    ) {
        self.snapshotCache = snapshotCache
        self.maximumRepositoryCount = max(1, maximumRepositoryCount)
    }

    /// Returns the current repository authority for a fallback round.
    public func authority(
        for repositoryIdentity: GitTrackedChangesRepositoryIdentity,
        fallbackRoundID: GitFallbackRoundID?
    ) -> GitTrackedChangesSnapshotAuthority {
        let state = state(for: repositoryIdentity)
        return GitTrackedChangesSnapshotAuthority(
            repositoryIdentity: repositoryIdentity,
            repositoryEpoch: state.epoch,
            repositoryRevision: state.revision,
            fallbackRoundID: fallbackRoundID
        )
    }

    /// Advances repository revision before watcher-triggered work is queued.
    @discardableResult
    public func recordWatcherEvent(
        for repositoryIdentity: GitTrackedChangesRepositoryIdentity,
        source: GitTrackedPathEventSource = .unknown
    ) -> GitTrackedChangesSnapshotAuthority {
        var state = state(for: repositoryIdentity)
        switch source {
        case .stable(let eventID):
            if state.stableWatcherEventIDsAreReliable,
               let lastEventID = state.lastStableWatcherEventID,
               eventID <= lastEventID {
                return snapshotAuthority(
                    repositoryIdentity: repositoryIdentity,
                    state: state,
                    fallbackRoundID: nil
                )
            }
            if state.stableWatcherEventIDsAreReliable {
                state.lastStableWatcherEventID = eventID
            }
        case .unknown:
            break
        case .sequenceReset:
            state.lastStableWatcherEventID = nil
            state.stableWatcherEventIDsAreReliable = false
        }
        if state.revision == .max {
            state.epoch = UUID()
            state.revision = 0
        } else {
            state.revision += 1
        }
        store(state, for: repositoryIdentity)
        return snapshotAuthority(
            repositoryIdentity: repositoryIdentity,
            state: state,
            fallbackRoundID: nil
        )
    }

    func snapshot(
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        authority: GitTrackedChangesSnapshotAuthority,
        load: @escaping @Sendable () -> GitTrackedChangesSnapshot
    ) async -> GitTrackedChangesSnapshotRead? {
        guard authority.repositoryIdentity.matches(repository) else {
            let snapshot = await Task.detached(priority: Task.currentPriority) {
                load()
            }.value
            return GitTrackedChangesSnapshotRead(snapshot: snapshot, isCurrent: false)
        }
        guard let snapshot = await snapshotCache.snapshot(
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority,
            load: load
        ) else { return nil }
        return validate(
            snapshot: snapshot,
            repository: repository,
            authority: authority
        )
    }

    /// Validates an uncached scan without running blocking filesystem work on
    /// this actor. The caller computes `snapshot` first, then this actor compares
    /// the stamped epoch/revision with current repository authority.
    func validate(
        snapshot: GitTrackedChangesSnapshot,
        repository: ResolvedGitRepository,
        authority: GitTrackedChangesSnapshotAuthority
    ) -> GitTrackedChangesSnapshotRead {
        guard authority.repositoryIdentity.matches(repository) else {
            return GitTrackedChangesSnapshotRead(snapshot: snapshot, isCurrent: false)
        }
        let currentState = repositoryStates[authority.repositoryIdentity]
        let isCurrent = currentState?.epoch == authority.repositoryEpoch
            && currentState?.revision == authority.repositoryRevision
        return GitTrackedChangesSnapshotRead(snapshot: snapshot, isCurrent: isCurrent)
    }

    func repositoryStateCountForTesting() -> Int {
        repositoryStates.count
    }

    private func state(
        for identity: GitTrackedChangesRepositoryIdentity
    ) -> RepositoryState {
        if let state = repositoryStates[identity] {
            touch(identity)
            return state
        }
        let state = RepositoryState()
        store(state, for: identity)
        return state
    }

    private func snapshotAuthority(
        repositoryIdentity: GitTrackedChangesRepositoryIdentity,
        state: RepositoryState,
        fallbackRoundID: GitFallbackRoundID?
    ) -> GitTrackedChangesSnapshotAuthority {
        GitTrackedChangesSnapshotAuthority(
            repositoryIdentity: repositoryIdentity,
            repositoryEpoch: state.epoch,
            repositoryRevision: state.revision,
            fallbackRoundID: fallbackRoundID
        )
    }

    private func store(
        _ state: RepositoryState,
        for identity: GitTrackedChangesRepositoryIdentity
    ) {
        touch(identity)
        repositoryStates[identity] = state
        while repositoryStates.count > maximumRepositoryCount,
              let oldest = repositoryInsertionOrder.first {
            repositoryInsertionOrder.removeFirst()
            repositoryStates.removeValue(forKey: oldest)
        }
    }

    private func touch(_ identity: GitTrackedChangesRepositoryIdentity) {
        repositoryInsertionOrder.removeAll { $0 == identity }
        repositoryInsertionOrder.append(identity)
    }
}
