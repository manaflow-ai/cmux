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

    @discardableResult
    func adopt(
        _ shims: TerminalSurfaceAgentCommandShimSet
    ) -> TerminalSurfaceAgentCommandShimLease {
        let directoryPath = shims.directoryPath
        if let retainedLease = leases[directoryPath] {
            return retainedLease.lease
        }
        let lease = TerminalSurfaceAgentCommandShimLease(
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
        return lease
    }

    func cleanup(
        _ shims: TerminalSurfaceAgentCommandShimSet,
        retryClock: any Clock<Duration>
    ) async {
        let directoryPath = shims.directoryPath
        let lease = adopt(shims)

        if await lease.release(removalClock: retryClock) {
            finish(directoryPath: directoryPath, lease: lease)
        } else {
            markForRetry(directoryPath: directoryPath, lease: lease)
            scheduleRetries(retryClock: retryClock)
        }
    }

    func prepareForInstall(
        retryClock: any Clock<Duration>
    ) async -> Bool {
        // A failed directory remains owned after its bounded retry schedule.
        // Sweep retained work before another install, and reject the install
        // while any directory remains. This bounds stale directories to shims
        // that were already installed when the first cleanup stopped succeeding.
        guard !leases.isEmpty else { return true }
        guard retryTask == nil, activeRetryGeneration == nil else { return false }
        nextRetryGeneration &+= 1
        let generation = nextRetryGeneration
        activeRetryGeneration = generation
        if await retryAll(generation: generation, retryClock: retryClock) {
            return true
        }
        guard activeRetryGeneration == generation else { return leases.isEmpty }
        activeRetryGeneration = nil
        scheduleRetries(retryClock: retryClock)
        return false
    }

    private func scheduleRetries(
        retryClock: any Clock<Duration>
    ) {
        guard retryTask == nil,
              activeRetryGeneration == nil,
              !leases.isEmpty else { return }
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
        // Keep fully attempted leases for a later install-time sweep. Only work
        // that arrived after this generation's final snapshot starts a new
        // schedule now.
        let hasUnattemptedWork = leases.values.contains { retainedLease in
            retainedLease.lastRetryGeneration != generation
                || retainedLease.lastRetryRevision != retainedLease.revision
        }
        activeRetryGeneration = nil
        retryTask = nil
        if hasUnattemptedWork {
            scheduleRetries(retryClock: retryClock)
        }
    }
}
