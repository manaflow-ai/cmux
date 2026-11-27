import Foundation

private let simulatorCameraCleanupWaitTimeout: Duration = .seconds(3)

struct SimulatorCameraCleanupSnapshot: Sendable {
    let deviceIdentifier: String?
    let bundleIdentifiers: [String]
    let ownershipTokens: [String: UUID]
}

extension SimulatorWorkerClient {
    func cameraCleanupSnapshot() -> SimulatorCameraCleanupSnapshot {
        let bundleIdentifiers = Array(cameraCleanupBundleIdentifiers.union(
            cameraReplayConfigurations.compactMap(\.targetBundleIdentifier)
        ).filter { !$0.isEmpty }).sorted()
        return SimulatorCameraCleanupSnapshot(
            deviceIdentifier: simulatorAttachedDeviceIdentifier(from: lastAttachment),
            bundleIdentifiers: bundleIdentifiers,
            ownershipTokens: cameraCleanupOwners.filter { bundleIdentifiers.contains($0.key) }
        )
    }

    func claimCameraCleanupOwnership(bundleIdentifier: String) async throws {
        guard !bundleIdentifier.isEmpty,
              let deviceIdentifier = simulatorAttachedDeviceIdentifier(from: lastAttachment)
        else { return }
        let owner = try await cameraCleanupCoordinator.claim(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier,
            sleeper: sleeper
        )
        cameraCleanupBundleIdentifiers.insert(bundleIdentifier)
        cameraCleanupOwners[bundleIdentifier] = owner
    }

    func prepareCameraCleanupOwnership(
        for message: SimulatorWorkerInbound
    ) async throws {
        switch message {
        case let .configureCamera(_, configuration):
            if let bundleIdentifier = configuration.targetBundleIdentifier {
                try await claimCameraCleanupOwnership(bundleIdentifier: bundleIdentifier)
            }
        case .switchCameraSource:
            for bundleIdentifier in cameraReplayConfigurations.compactMap(
                \.targetBundleIdentifier
            ) {
                try await claimCameraCleanupOwnership(bundleIdentifier: bundleIdentifier)
            }
        default:
            break
        }
    }

    func cameraOwnershipFailure(_ error: Error) -> SimulatorFailure {
        SimulatorFailure(
            code: "simulator_camera_ownership_unavailable",
            message: error.localizedDescription,
            isRecoverable: true
        )
    }

    func sendClosingMessages(shutdown: Bool) {
        guard let child else { return }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(SimulatorWorkerInbound.releaseInputs) {
            try? child.send(data)
        }
        guard shutdown,
              let data = try? encoder.encode(SimulatorWorkerInbound.shutdown) else { return }
        try? child.send(data)
    }

    func enqueueCameraCleanup(_ snapshot: SimulatorCameraCleanupSnapshot) async {
        guard let deviceIdentifier = snapshot.deviceIdentifier,
              !snapshot.bundleIdentifiers.isEmpty else { return }
        let snapshot = mergedCameraCleanupSnapshot(
            pendingCameraCleanupSnapshot,
            with: snapshot
        )
        pendingCameraCleanupSnapshot = snapshot
        cameraCleanupRevision &+= 1
        let simulatorControl = self.simulatorControl
        let permit = cameraCleanupPermit
        let cleanupCoordinator = cameraCleanupCoordinator
        cameraCleanupTask = await cameraCleanupCoordinator.enqueue(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifiers: snapshot.bundleIdentifiers
        ) {
            guard !Task.isCancelled, await permit.allowsMutation() else {
                return .failed(simulatorCameraCleanupCancellationFailure())
            }
            return await cleanSimulatorCameraInjections(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifiers: snapshot.bundleIdentifiers,
                simulatorControl: simulatorControl,
                ownershipTokens: snapshot.ownershipTokens,
                cleanupCoordinator: cleanupCoordinator,
                permit: permit
            )
        }
    }

    @discardableResult
    func waitForCameraCleanup() async -> Bool {
        while true {
            let task: Task<SimulatorCameraCleanupResult, Never>?
            if let localTask = cameraCleanupTask {
                task = localTask
            } else if let pendingCameraCleanupSnapshot {
                await enqueueCameraCleanup(pendingCameraCleanupSnapshot)
                continue
            } else {
                task = nil
            }
            guard let task else { return true }
            let revision = cameraCleanupRevision
            let outcome = await SimulatorCameraCleanupWaitState().wait(
                for: task,
                timeout: simulatorCameraCleanupWaitTimeout,
                sleeper: sleeper
            )
            switch outcome {
            case .completed(.completed):
                if revision == cameraCleanupRevision {
                    cameraCleanupTask = nil
                    pendingCameraCleanupSnapshot = nil
                    cameraCleanupFailure = nil
                    return true
                }
            case let .completed(.failed(failure)):
                if revision == cameraCleanupRevision {
                    cameraCleanupTask = nil
                    cameraCleanupFailure = failure
                    if let pendingCameraCleanupSnapshot {
                        await enqueueCameraCleanup(pendingCameraCleanupSnapshot)
                    }
                }
                return false
            case .timedOut, .cancelled:
                // Bound the caller's wait without discarding the cleanup. The
                // next activation must fail and retry after the obligation finishes.
                return false
            }
        }
    }

}

func cleanSimulatorCameraInjections(
    deviceIdentifier: String,
    bundleIdentifiers: [String],
    simulatorControl: any SimulatorControlling,
    ownershipTokens: [String: UUID],
    cleanupCoordinator: SimulatorCameraCleanupCoordinator,
    permit: SimulatorCameraCleanupPermit? = nil
) async -> SimulatorCameraCleanupResult {
    var result = SimulatorCameraCleanupResult.completed
    for bundleIdentifier in bundleIdentifiers {
        guard let ownershipToken = ownershipTokens[bundleIdentifier] else { continue }
        let mutationIsAllowed = await permit?.allowsMutation() ?? true
        if Task.isCancelled || !mutationIsAllowed {
            return .failed(simulatorCameraCleanupCancellationFailure())
        }
        guard await cleanupCoordinator.isCurrent(
            ownershipToken,
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        ) else { continue }
        do {
            _ = try await simulatorControl.perform(.cleanupCameraApplication(
                deviceID: deviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                ownershipToken: ownershipToken
            ))
        } catch is CancellationError {
            return .failed(simulatorCameraCleanupCancellationFailure())
        } catch let failure as SimulatorFailure {
            result = .failed(failure)
        } catch let error as SimulatorControlError {
            result = .failed(SimulatorFailure(
                code: error.code,
                message: error.message,
                isRecoverable: true
            ))
        } catch {
            result = .failed(SimulatorFailure(
                code: "simulator_camera_cleanup_failed",
                message: error.localizedDescription,
                isRecoverable: true
            ))
        }
    }
    return result
}

func simulatorCameraCleanupCancellationFailure() -> SimulatorFailure {
    SimulatorFailure(
        code: "simulator_camera_cleanup_cancelled",
        message: String(
            localized: "simulator.failure.cameraCleanupPending",
            defaultValue: "Camera cleanup is still running. Retry after it finishes."
        ),
        isRecoverable: true
    )
}

func mergedCameraCleanupSnapshot(
    _ existing: SimulatorCameraCleanupSnapshot?,
    with incoming: SimulatorCameraCleanupSnapshot
) -> SimulatorCameraCleanupSnapshot {
    guard existing?.deviceIdentifier == incoming.deviceIdentifier,
          let existing else { return incoming }
    let bundleIdentifiers = Array(Set(
        existing.bundleIdentifiers + incoming.bundleIdentifiers
    )).sorted()
    return SimulatorCameraCleanupSnapshot(
        deviceIdentifier: incoming.deviceIdentifier,
        bundleIdentifiers: bundleIdentifiers,
        ownershipTokens: existing.ownershipTokens.merging(
            incoming.ownershipTokens
        ) { _, incoming in incoming }
    )
}

func simulatorAttachedDeviceIdentifier(
    from attachment: SimulatorWorkerInbound?
) -> String? {
    guard case let .attach(deviceIdentifier, _) = attachment else { return nil }
    return deviceIdentifier
}

func unlinkSimulatorCameraSharedMemory(
    connection: SimulatorWorkerConnection,
    deviceIdentifier: String?,
    token: String
) {
    guard let deviceIdentifier,
          let processIdentifier = connection.processIdentifier,
          processIdentifier > 1 else { return }
    SimulatorCameraSharedMemory(
        deviceIdentifier: deviceIdentifier,
        processIdentifier: processIdentifier,
        token: token
    ).unlink()
}
