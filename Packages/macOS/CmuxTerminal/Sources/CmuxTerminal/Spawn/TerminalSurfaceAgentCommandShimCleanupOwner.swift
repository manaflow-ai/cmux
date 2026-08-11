internal import CmuxTerminalCore

actor TerminalSurfaceAgentCommandShimCleanupOwner {
    private struct RetainedLease {
        let lease: TerminalSurfaceAgentCommandShimLease
        var revision: UInt64
        var lastRetryGeneration: UInt64?
        var lastRetryRevision: UInt64?
    }

    private let removalAttemptLimit: Int
    private let removalLane: TerminalSurfaceAgentCommandShimRemovalLane
    private let retryDelays: [Duration]
    private let remove: @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void
    private let reportRemovalFailure:
        @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void
    private var leases: [String: RetainedLease] = [:]
    private var nextLeaseRevision: UInt64 = 0
    private var nextRetryGeneration: UInt64 = 0
    private var activeRetryGeneration: UInt64?
    private var retryTask: Task<Void, Never>?

    var retainedLeaseCount: Int { leases.count }
    var pendingRetryCount: Int { retryTask == nil ? 0 : 1 }

    init(
        removalAttemptLimit: Int,
        removalLane: TerminalSurfaceAgentCommandShimRemovalLane,
        retryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)],
        remove: @escaping @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void,
        reportRemovalFailure:
            @escaping @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void
    ) {
        precondition(removalAttemptLimit > 0)
        precondition(!retryDelays.isEmpty)
        precondition(retryDelays.allSatisfy { $0 > .zero })
        self.removalAttemptLimit = removalAttemptLimit
        self.removalLane = removalLane
        self.retryDelays = retryDelays
        self.remove = remove
        self.reportRemovalFailure = reportRemovalFailure
    }

    deinit { retryTask?.cancel() }

    func cleanup(
        _ shims: TerminalSurfaceAgentCommandShimSet,
        retryClock: any Clock<Duration>
    ) async {
        let directoryPath = shims.directoryPath
        let lease: TerminalSurfaceAgentCommandShimLease
        if let retainedLease = leases[directoryPath] {
            lease = retainedLease.lease
        } else {
            lease = TerminalSurfaceAgentCommandShimLease(
                shims: shims,
                removalAttemptLimit: removalAttemptLimit,
                removalLane: removalLane,
                remove: remove,
                reportRemovalFailure: reportRemovalFailure
            )
            leases[directoryPath] = RetainedLease(
                lease: lease,
                revision: nextRevision()
            )
        }

        if await lease.release(removalClock: retryClock) {
            finish(directoryPath: directoryPath, lease: lease)
        } else {
            markForRetry(directoryPath: directoryPath, lease: lease)
            scheduleRetries(retryClock: retryClock)
        }
    }

    private func scheduleRetries(
        retryClock: any Clock<Duration>
    ) {
        guard retryTask == nil, !leases.isEmpty else { return }
        let retryDelays = retryDelays
        nextRetryGeneration &+= 1
        let generation = nextRetryGeneration
        activeRetryGeneration = generation
        retryTask = Task.detached(priority: .utility) { [weak self] in
            for delay in retryDelays {
                do {
                    try await retryClock.sleep(for: delay, tolerance: nil)
                } catch {
                    return
                }
                guard let self else { return }
                if await self.retryAll(
                    generation: generation,
                    retryClock: retryClock
                ) {
                    return
                }
            }
            await self?.finishRetrySchedule(
                generation: generation,
                retryClock: retryClock
            )
        }
    }

    private func retryAll(
        generation: UInt64,
        retryClock: any Clock<Duration>
    ) async -> Bool {
        guard activeRetryGeneration == generation else { return true }
        let attempts = leases.map { directoryPath, retainedLease in
            (
                directoryPath: directoryPath,
                lease: retainedLease.lease,
                revision: retainedLease.revision
            )
        }
        for attempt in attempts {
            guard activeRetryGeneration == generation else { return true }
            guard let retainedLease = leases[attempt.directoryPath],
                  retainedLease.lease === attempt.lease,
                  retainedLease.revision == attempt.revision
            else { continue }

            let succeeded = await attempt.lease.release(removalClock: retryClock)
            guard var currentLease = leases[attempt.directoryPath],
                  currentLease.lease === attempt.lease
            else { continue }
            if succeeded {
                leases[attempt.directoryPath] = nil
            } else if activeRetryGeneration == generation,
                      currentLease.revision == attempt.revision
            {
                currentLease.lastRetryGeneration = generation
                currentLease.lastRetryRevision = attempt.revision
                leases[attempt.directoryPath] = currentLease
            }
        }
        guard activeRetryGeneration == generation else { return true }
        guard leases.isEmpty else { return false }
        activeRetryGeneration = nil
        retryTask = nil
        return true
    }

    private func finish(directoryPath: String, lease: TerminalSurfaceAgentCommandShimLease) {
        guard leases[directoryPath]?.lease === lease else { return }
        leases[directoryPath] = nil
        guard leases.isEmpty else { return }
        activeRetryGeneration = nil
        retryTask?.cancel()
        retryTask = nil
    }

    private func markForRetry(
        directoryPath: String,
        lease: TerminalSurfaceAgentCommandShimLease
    ) {
        guard var retainedLease = leases[directoryPath] else {
            leases[directoryPath] = RetainedLease(
                lease: lease,
                revision: nextRevision()
            )
            return
        }
        guard retainedLease.lease === lease else { return }
        retainedLease.revision = nextRevision()
        retainedLease.lastRetryGeneration = nil
        retainedLease.lastRetryRevision = nil
        leases[directoryPath] = retainedLease
    }

    private func nextRevision() -> UInt64 {
        nextLeaseRevision &+= 1
        return nextLeaseRevision
    }

    private func finishRetrySchedule(
        generation: UInt64,
        retryClock: any Clock<Duration>
    ) {
        guard activeRetryGeneration == generation else { return }
        for (directoryPath, retainedLease) in Array(leases)
        where retainedLease.lastRetryGeneration == generation
            && retainedLease.lastRetryRevision == retainedLease.revision
        {
            if leases[directoryPath]?.lease === retainedLease.lease {
                leases[directoryPath] = nil
            }
        }
        activeRetryGeneration = nil
        retryTask = nil
        scheduleRetries(retryClock: retryClock)
    }
}
