import Foundation

/// Bounded cache of tracked-change scans keyed by repository, index stat, and
/// namespaced caller-owned filesystem-event generation. Sharing one instance
/// also coalesces concurrent cache misses for the same key into one scan.
public actor GitTrackedChangesSnapshotCache {
    /// Cancellation must become visible synchronously in the caller's
    /// cancellation handler. The actor cleanup task can lose a race with the
    /// detached load's completion, so this small lock-protected token is the
    /// linearization point for cancellation versus result delivery.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<GitTrackedChangesSnapshot?, Never>?
        private var result: GitTrackedChangesSnapshot?
        private var isResolved = false

        func value() async -> GitTrackedChangesSnapshot? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isResolved {
                    let result = result
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        @discardableResult
        func cancel() -> Bool {
            resolve(with: nil)
        }

        @discardableResult
        func complete(with snapshot: GitTrackedChangesSnapshot) -> Bool {
            resolve(with: snapshot)
        }

        private func resolve(with result: GitTrackedChangesSnapshot?) -> Bool {
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return false
            }
            isResolved = true
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
            return true
        }
    }

    private struct InFlightSnapshot {
        let id: UUID
        let task: Task<GitTrackedChangesSnapshot, Never>
        var waitersByID: [UUID: Waiter]
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
        authority: GitTrackedChangesSnapshotAuthority
    ) -> GitTrackedChangesSnapshot? {
        let key = GitTrackedChangesSnapshotCacheKey(
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority
        )
        guard let snapshot = entriesByKey[key]?.snapshot else { return nil }
        CmuxGitRuntimeMetrics.recordTrackedStatusCacheHit()
        return snapshot
    }

    func snapshot(
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        authority: GitTrackedChangesSnapshotAuthority,
        load: @escaping @Sendable () -> GitTrackedChangesSnapshot
    ) async -> GitTrackedChangesSnapshot? {
        guard !Task.isCancelled else { return nil }
        let key = GitTrackedChangesSnapshotCacheKey(
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority
        )
        if let snapshot = entriesByKey[key]?.snapshot {
            CmuxGitRuntimeMetrics.recordTrackedStatusCacheHit()
            return snapshot
        }

        let waiterID = UUID()
        let waiter = Waiter()
        registerWaiter(
            waiterID,
            waiter: waiter,
            key: key,
            load: load
        )
        let snapshot = await withTaskCancellationHandler {
            await waiter.value()
        } onCancel: {
            waiter.cancel()
        }
        if snapshot == nil {
            removeCanceledWaiter(waiterID, key: key)
        }
        return snapshot
    }

    func store(
        _ snapshot: GitTrackedChangesSnapshot,
        repository: ResolvedGitRepository,
        indexStatSignature: GitIndexStatSignature,
        authority: GitTrackedChangesSnapshotAuthority
    ) {
        let key = GitTrackedChangesSnapshotCacheKey(
            repository: repository,
            indexStatSignature: indexStatSignature,
            authority: authority
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

    private func registerWaiter(
        _ waiterID: UUID,
        waiter: Waiter,
        key: GitTrackedChangesSnapshotCacheKey,
        load: @escaping @Sendable () -> GitTrackedChangesSnapshot
    ) {
        guard !Task.isCancelled else {
            waiter.cancel()
            return
        }
        if var inFlight = inFlightSnapshotsByKey[key] {
            CmuxGitRuntimeMetrics.recordTrackedStatusInFlightJoin()
            inFlight.waitersByID[waiterID] = waiter
            inFlightSnapshotsByKey[key] = inFlight
            return
        }

        let operationID = UUID()
        let task = Task.detached(priority: Task.currentPriority) {
            load()
        }
        inFlightSnapshotsByKey[key] = InFlightSnapshot(
            id: operationID,
            task: task,
            waitersByID: [waiterID: waiter]
        )
        Task { [weak self] in
            let snapshot = await task.value
            await self?.completeOperation(
                operationID,
                snapshot: snapshot,
                key: key
            )
        }
    }

    private func removeCanceledWaiter(
        _ waiterID: UUID,
        key: GitTrackedChangesSnapshotCacheKey
    ) {
        guard var inFlight = inFlightSnapshotsByKey[key],
              let waiter = inFlight.waitersByID.removeValue(forKey: waiterID) else { return }
        waiter.cancel()
        if inFlight.waitersByID.isEmpty {
            inFlightSnapshotsByKey.removeValue(forKey: key)
            inFlight.task.cancel()
        } else {
            inFlightSnapshotsByKey[key] = inFlight
        }
    }

    private func completeOperation(
        _ operationID: UUID,
        snapshot: GitTrackedChangesSnapshot,
        key: GitTrackedChangesSnapshotCacheKey
    ) {
        guard let inFlight = inFlightSnapshotsByKey[key],
              inFlight.id == operationID else { return }
        inFlightSnapshotsByKey.removeValue(forKey: key)
        var deliveredResult = false
        for waiter in inFlight.waitersByID.values {
            deliveredResult = waiter.complete(with: snapshot) || deliveredResult
        }
        if deliveredResult {
            store(snapshot, for: key)
        }
    }

    private func evictOldestEntriesIfNeeded() {
        while entriesByKey.count > maximumEntryCount,
              let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entriesByKey.removeValue(forKey: oldest)
        }
    }
}
