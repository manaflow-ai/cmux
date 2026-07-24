import Foundation

enum SimulatorCameraCleanupResult: Equatable, Sendable {
    case completed
    case failed(SimulatorFailure)
}

/// Serializes camera cleanup per Simulator application across worker-client
/// replacement without blocking unrelated devices or bundle identifiers.
actor SimulatorCameraCleanupCoordinator {
    private struct Target: Hashable {
        let deviceIdentifier: String
        let bundleIdentifier: String
    }

    private var tailByTarget: [Target: Task<SimulatorCameraCleanupResult, Never>] = [:]
    private var revisionByTarget: [Target: UInt64] = [:]
    private var ownerByTarget: [Target: UUID] = [:]
    private let ownershipStore: SimulatorCrossProcessOwnershipStore

    var trackedTargetCount: Int {
        Set(tailByTarget.keys)
            .union(revisionByTarget.keys)
            .union(ownerByTarget.keys)
            .count
    }

    init(
        ownershipStore: SimulatorCrossProcessOwnershipStore =
            SimulatorCrossProcessOwnershipStore()
    ) {
        self.ownershipStore = ownershipStore
    }

    func claim(
        deviceIdentifier: String,
        bundleIdentifier: String,
        timeout: Duration = .seconds(3),
        sleeper: any SimulatorWorkerSleeping = ContinuousSimulatorWorkerSleeper()
    ) async throws -> UUID {
        let target = Target(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        if tailByTarget[target] != nil {
            let pendingCleanup = Task<SimulatorCameraCleanupResult, Never> {
                await self.waitForCurrentCleanup(of: target)
            }
            defer { pendingCleanup.cancel() }
            let outcome = await SimulatorCameraCleanupWaitState().wait(
                for: pendingCleanup,
                timeout: timeout,
                sleeper: sleeper
            )
            switch outcome {
            case .completed(.completed):
                break
            case let .completed(.failed(failure)):
                throw failure
            case .timedOut:
                throw SimulatorFailure(
                    code: "simulator_camera_cleanup_pending",
                    message: String(
                        localized: "simulator.failure.cameraCleanupPending",
                        defaultValue: "Camera cleanup is still running. Retry after it finishes."
                    ),
                    isRecoverable: true
                )
            case .cancelled:
                throw CancellationError()
            }
        }
        try Task.checkCancellation()
        let owner = try ownershipStore.claim(
            namespace: "camera",
            components: [deviceIdentifier, bundleIdentifier]
        )
        ownerByTarget[target] = owner
        return owner
    }

    func isCurrent(
        _ owner: UUID,
        deviceIdentifier: String,
        bundleIdentifier: String
    ) -> Bool {
        ownerByTarget[Target(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )] == owner && ownershipStore.isCurrent(
            owner,
            namespace: "camera",
            components: [deviceIdentifier, bundleIdentifier]
        )
    }

    func enqueue(
        deviceIdentifier: String,
        bundleIdentifiers: [String],
        _ operation: @escaping @Sendable () async -> SimulatorCameraCleanupResult
    ) -> Task<SimulatorCameraCleanupResult, Never> {
        let targets = Set(bundleIdentifiers.filter { !$0.isEmpty }.map {
            Target(deviceIdentifier: deviceIdentifier, bundleIdentifier: $0)
        })
        let previous = targets.compactMap { tailByTarget[$0] }
        let owners = Dictionary(uniqueKeysWithValues: targets.compactMap { target in
            ownerByTarget[target].map { (target, $0) }
        })
        let task = Task<SimulatorCameraCleanupResult, Never> {
            for pendingCleanup in previous {
                _ = await pendingCleanup.value
            }
            guard !Task.isCancelled else {
                return .failed(simulatorCameraCleanupCancellationFailure())
            }
            return await operation()
        }
        var revisions: [Target: UInt64] = [:]
        for target in targets {
            let revision = (revisionByTarget[target] ?? 0) &+ 1
            revisionByTarget[target] = revision
            tailByTarget[target] = task
            revisions[target] = revision
        }
        Task { [weak self] in
            let result = await task.value
            await self?.finish(revisions: revisions, owners: owners, result: result)
        }
        return task
    }

    private func finish(
        revisions: [Target: UInt64],
        owners: [Target: UUID],
        result: SimulatorCameraCleanupResult
    ) {
        guard result == .completed else { return }
        for (target, revision) in revisions
        where revisionByTarget[target] == revision {
            tailByTarget.removeValue(forKey: target)
            revisionByTarget.removeValue(forKey: target)
            if let owner = owners[target], ownerByTarget[target] == owner {
                ownerByTarget.removeValue(forKey: target)
            }
        }
    }

    private func waitForCurrentCleanup(
        of target: Target
    ) async -> SimulatorCameraCleanupResult {
        while !Task.isCancelled,
              let pendingCleanup = tailByTarget[target] {
            let observedRevision = revisionByTarget[target]
            let result = await pendingCleanup.value
            guard revisionByTarget[target] == observedRevision else { continue }
            return result
        }
        return Task.isCancelled
            ? .failed(simulatorCameraCleanupCancellationFailure())
            : .completed
    }
}
