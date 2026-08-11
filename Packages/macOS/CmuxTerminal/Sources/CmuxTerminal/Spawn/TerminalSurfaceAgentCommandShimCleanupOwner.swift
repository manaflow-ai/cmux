internal import CmuxTerminalCore

actor TerminalSurfaceAgentCommandShimCleanupOwner {
    private let removalAttemptLimit: Int
    private let removalLane: TerminalSurfaceAgentCommandShimRemovalLane
    private let retryDelays: [Duration]
    private let remove: @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void
    private let reportRemovalFailure:
        @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void
    private var leases: [String: TerminalSurfaceAgentCommandShimLease] = [:]
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
            lease = retainedLease
        } else {
            lease = TerminalSurfaceAgentCommandShimLease(
                shims: shims,
                removalAttemptLimit: removalAttemptLimit,
                removalLane: removalLane,
                remove: remove,
                reportRemovalFailure: reportRemovalFailure
            )
            leases[directoryPath] = lease
        }

        if await lease.release(removalClock: retryClock) {
            finish(directoryPath: directoryPath)
        } else {
            scheduleRetries(retryClock: retryClock)
        }
    }

    private func scheduleRetries(
        retryClock: any Clock<Duration>
    ) {
        guard retryTask == nil else { return }
        let retryDelays = retryDelays
        retryTask = Task.detached(priority: .utility) { [weak self] in
            var delayIndex = 0
            while !Task.isCancelled {
                let delay = retryDelays[delayIndex]
                do {
                    try await retryClock.sleep(for: delay, tolerance: nil)
                } catch {
                    return
                }
                guard let self else { return }
                if await self.retryAll(retryClock: retryClock) {
                    return
                }
                delayIndex = (delayIndex + 1) % retryDelays.count
            }
        }
    }

    private func retryAll(
        retryClock: any Clock<Duration>
    ) async -> Bool {
        for directoryPath in Array(leases.keys) {
            guard let lease = leases[directoryPath] else { continue }
            if await lease.release(removalClock: retryClock) {
                leases[directoryPath] = nil
            }
        }
        guard leases.isEmpty else { return false }
        retryTask = nil
        return true
    }

    private func finish(directoryPath: String) {
        leases[directoryPath] = nil
        guard leases.isEmpty else { return }
        retryTask?.cancel()
        retryTask = nil
    }
}
