import Foundation

typealias SimulatorCameraCleanupOperation =
    @Sendable () async -> SimulatorCameraCleanupResult

/// Serializes camera cleanup per Simulator application across worker-client
/// replacement without blocking unrelated devices or bundle identifiers.
actor SimulatorCameraCleanupCoordinator {
    private var tailByTarget:
        [SimulatorCameraCleanupTarget: Task<SimulatorCameraCleanupResult, Never>] = [:]
    private var revisionByTarget: [SimulatorCameraCleanupTarget: UInt64] = [:]
    private var ownerByTarget: [SimulatorCameraCleanupTarget: UUID] = [:]
    private var recoveryIdentifierByTarget: [SimulatorCameraCleanupTarget: UUID] = [:]
    private var recoveryOperationByIdentifier:
        [UUID: SimulatorCameraCleanupOperation] = [:]
    private let ownershipStore: SimulatorCrossProcessOwnershipStore

    var trackedTargetCount: Int {
        Set(tailByTarget.keys)
            .union(revisionByTarget.keys)
            .union(ownerByTarget.keys)
            .union(recoveryIdentifierByTarget.keys)
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
        let target = SimulatorCameraCleanupTarget(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        var retriedRecoveryIdentifiers = Set<UUID>()
        while let pendingCleanup = tailByTarget[target],
              let revision = revisionByTarget[target] {
            let outcome = await SimulatorCameraCleanupWaitState().wait(
                for: pendingCleanup,
                timeout: timeout,
                sleeper: sleeper
            )
            switch outcome {
            case .completed(.completed):
                guard revisionByTarget[target] == revision else { continue }
                clearSuccessfulCleanup(target: target, revision: revision)
            case let .completed(.failed(failure)):
                guard revisionByTarget[target] == revision else { continue }
                if let recoveryIdentifier = recoveryIdentifierByTarget[target],
                   !retriedRecoveryIdentifiers.contains(recoveryIdentifier),
                   retryRetainedCleanup(
                       target: target,
                       revision: revision
                   ) != nil {
                    retriedRecoveryIdentifiers.insert(recoveryIdentifier)
                    continue
                }
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
        ownerByTarget[SimulatorCameraCleanupTarget(
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
        _ operation: @escaping SimulatorCameraCleanupOperation
    ) -> Task<SimulatorCameraCleanupResult, Never> {
        let targets = Set(bundleIdentifiers.filter { !$0.isEmpty }.map {
            SimulatorCameraCleanupTarget(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: $0
            )
        })
        guard !targets.isEmpty else {
            return Task { await operation() }
        }
        return schedule(
            targets: targets,
            recoveryIdentifier: UUID(),
            operation: operation
        )
    }

    func waitForPendingCleanup() async -> Bool {
        var allCleanupCompleted = true
        var retriedRecoveryIdentifiers = Set<UUID>()
        var observedRevisions: [SimulatorCameraCleanupTarget: UInt64] = [:]
        while true {
            guard !Task.isCancelled else { return false }
            let pending = revisionByTarget.compactMap { target, revision in
                tailByTarget[target].map { (target, revision, $0) }
            }
            guard !pending.isEmpty else { return allCleanupCompleted }
            for (target, revision, task) in pending {
                let result = await task.value
                guard !Task.isCancelled else { return false }
                guard revisionByTarget[target] == revision else { continue }
                observedRevisions[target] = revision
                switch result {
                case .completed:
                    clearSuccessfulCleanup(target: target, revision: revision)
                case .failed:
                    if let recoveryIdentifier = recoveryIdentifierByTarget[target],
                       !retriedRecoveryIdentifiers.contains(recoveryIdentifier),
                       retryRetainedCleanup(
                           target: target,
                           revision: revision
                       ) != nil {
                        retriedRecoveryIdentifiers.insert(recoveryIdentifier)
                    } else {
                        allCleanupCompleted = false
                    }
                }
            }
            let hasNewCleanup = revisionByTarget.contains { target, revision in
                observedRevisions[target] != revision
            }
            if !hasNewCleanup { return allCleanupCompleted }
        }
    }

    /// Cancels every currently owned rollback and joins it for one bounded
    /// grace period. A task that ignores cancellation remains retained for a
    /// later retry, but cannot keep AppKit's terminate request unresolved.
    func cancelPendingCleanupAndWait(
        timeout: Duration,
        sleeper: any SimulatorWorkerSleeping = ContinuousSimulatorWorkerSleeper()
    ) async -> Bool {
        let pending = Array(tailByTarget.values)
        guard !pending.isEmpty else { return true }
        pending.forEach { $0.cancel() }
        let join = Task<SimulatorCameraCleanupResult, Never> {
            for task in pending {
                _ = await task.value
            }
            return .completed
        }
        let outcome = await SimulatorCameraCleanupWaitState().wait(
            for: join,
            timeout: timeout,
            sleeper: sleeper
        )
        join.cancel()
        if case .completed = outcome {
            return true
        }
        return false
    }

    private func schedule(
        targets: Set<SimulatorCameraCleanupTarget>,
        recoveryIdentifier: UUID,
        operation: @escaping SimulatorCameraCleanupOperation
    ) -> Task<SimulatorCameraCleanupResult, Never> {
        let previous = targets.compactMap { tailByTarget[$0] }
        let task = Task<SimulatorCameraCleanupResult, Never> {
            for pendingCleanup in previous {
                _ = await pendingCleanup.value
            }
            guard !Task.isCancelled else {
                return .failed(simulatorCameraCleanupCancellationFailure())
            }
            return await operation()
        }
        recoveryOperationByIdentifier[recoveryIdentifier] = operation
        var displacedRecoveryIdentifiers = Set<UUID>()
        var revisions: [SimulatorCameraCleanupTarget: UInt64] = [:]
        for target in targets {
            if let displaced = recoveryIdentifierByTarget.updateValue(
                recoveryIdentifier,
                forKey: target
            ), displaced != recoveryIdentifier {
                displacedRecoveryIdentifiers.insert(displaced)
            }
            let revision = (revisionByTarget[target] ?? 0) &+ 1
            revisionByTarget[target] = revision
            tailByTarget[target] = task
            revisions[target] = revision
        }
        for displaced in displacedRecoveryIdentifiers {
            pruneRecoveryOperationIfUnused(displaced)
        }
        Task { [weak self] in
            let result = await task.value
            await self?.finish(
                revisions: revisions,
                recoveryIdentifier: recoveryIdentifier,
                result: result
            )
        }
        return task
    }

    private func retryRetainedCleanup(
        target: SimulatorCameraCleanupTarget,
        revision: UInt64
    ) -> UUID? {
        guard revisionByTarget[target] == revision,
              let recoveryIdentifier = recoveryIdentifierByTarget[target],
              let operation = recoveryOperationByIdentifier[recoveryIdentifier]
        else { return nil }
        let targets = Set(recoveryIdentifierByTarget.compactMap {
            $0.value == recoveryIdentifier ? $0.key : nil
        })
        guard !targets.isEmpty else { return nil }
        _ = schedule(
            targets: targets,
            recoveryIdentifier: recoveryIdentifier,
            operation: operation
        )
        return recoveryIdentifier
    }

    private func clearSuccessfulCleanup(
        target: SimulatorCameraCleanupTarget,
        revision: UInt64
    ) {
        guard revisionByTarget[target] == revision else { return }
        tailByTarget.removeValue(forKey: target)
        revisionByTarget.removeValue(forKey: target)
        ownerByTarget.removeValue(forKey: target)
        if let recoveryIdentifier = recoveryIdentifierByTarget.removeValue(forKey: target) {
            pruneRecoveryOperationIfUnused(recoveryIdentifier)
        }
    }

    private func finish(
        revisions: [SimulatorCameraCleanupTarget: UInt64],
        recoveryIdentifier: UUID,
        result: SimulatorCameraCleanupResult
    ) {
        guard result == .completed else { return }
        for (target, revision) in revisions
        where revisionByTarget[target] == revision {
            clearSuccessfulCleanup(target: target, revision: revision)
        }
        pruneRecoveryOperationIfUnused(recoveryIdentifier)
    }

    private func pruneRecoveryOperationIfUnused(_ recoveryIdentifier: UUID) {
        guard !recoveryIdentifierByTarget.values.contains(recoveryIdentifier) else {
            return
        }
        recoveryOperationByIdentifier.removeValue(forKey: recoveryIdentifier)
    }
}
