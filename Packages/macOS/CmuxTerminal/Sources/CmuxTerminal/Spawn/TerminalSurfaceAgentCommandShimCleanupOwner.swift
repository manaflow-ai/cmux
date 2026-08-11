internal import CmuxTerminalCore

actor TerminalSurfaceAgentCommandShimCleanupOwner {
    private let removalAttemptLimit: Int
    private let retryDelays: [Duration]
    private let remove: @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void
    private let reportRemovalFailure:
        @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void
    private var leases: [String: TerminalSurfaceAgentCommandShimLease] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]

    var retainedLeaseCount: Int { leases.count }
    var pendingRetryCount: Int { retryTasks.count }

    init(
        removalAttemptLimit: Int,
        retryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)],
        remove: @escaping @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void,
        reportRemovalFailure:
            @escaping @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void
    ) {
        precondition(removalAttemptLimit > 0)
        precondition(retryDelays.allSatisfy { $0 > .zero })
        self.removalAttemptLimit = removalAttemptLimit
        self.retryDelays = retryDelays
        self.remove = remove
        self.reportRemovalFailure = reportRemovalFailure
    }

    deinit {
        for task in retryTasks.values {
            task.cancel()
        }
    }

    func cleanup(
        _ shims: TerminalSurfaceAgentCommandShimSet,
        retryClock: any Clock<Duration>
    ) async {
        let directoryPath = shims.directoryPath
        let lease: TerminalSurfaceAgentCommandShimLease
        if let retainedLease = leases[directoryPath] {
            lease = retainedLease
        } else {
            lease = TerminalSurfaceAgentCommandShimLease(
                shims: shims,
                removalAttemptLimit: removalAttemptLimit,
                remove: remove,
                reportRemovalFailure: reportRemovalFailure
            )
            leases[directoryPath] = lease
        }

        if await lease.release(removalClock: retryClock) {
            finish(directoryPath: directoryPath)
        } else {
            scheduleRetries(directoryPath: directoryPath, retryClock: retryClock)
        }
    }

    private func scheduleRetries(
        directoryPath: String,
        retryClock: any Clock<Duration>
    ) {
        guard retryTasks[directoryPath] == nil else { return }
        let retryDelays = retryDelays
        retryTasks[directoryPath] = Task.detached(priority: .utility) { [weak self] in
            for delay in retryDelays {
                do {
                    try await retryClock.sleep(for: delay, tolerance: nil)
                } catch {
                    return
                }
                guard let self else { return }
                if await self.retry(directoryPath: directoryPath, retryClock: retryClock) {
                    return
                }
            }
            await self?.finish(directoryPath: directoryPath)
        }
    }

    private func retry(
        directoryPath: String,
        retryClock: any Clock<Duration>
    ) async -> Bool {
        guard let lease = leases[directoryPath] else {
            finish(directoryPath: directoryPath)
            return true
        }
        guard await lease.release(removalClock: retryClock) else { return false }
        finish(directoryPath: directoryPath)
        return true
    }

    private func finish(directoryPath: String) {
        leases[directoryPath] = nil
        retryTasks.removeValue(forKey: directoryPath)?.cancel()
    }
}
