import Foundation

private let simulatorCameraCleanupWaitTimeout: Duration = .seconds(3)

struct SimulatorCameraCleanupSnapshot: Sendable {
    let deviceIdentifier: String?
    let bundleIdentifiers: [String]
}

extension SimulatorWorkerClient {
    func cameraCleanupSnapshot() -> SimulatorCameraCleanupSnapshot {
        SimulatorCameraCleanupSnapshot(
            deviceIdentifier: simulatorAttachedDeviceIdentifier(from: lastAttachment),
            bundleIdentifiers: Array(cameraCleanupBundleIdentifiers.union(
                cameraReplayConfigurations.compactMap(\.targetBundleIdentifier)
            ).filter { !$0.isEmpty }).sorted()
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

    func enqueueCameraCleanup(_ snapshot: SimulatorCameraCleanupSnapshot) {
        guard let deviceIdentifier = snapshot.deviceIdentifier,
              !snapshot.bundleIdentifiers.isEmpty else { return }
        cameraCleanupRevision &+= 1
        let previous = cameraCleanupTask
        let simulatorControl = self.simulatorControl
        let permit = cameraCleanupPermit
        cameraCleanupTask = Task {
            await previous?.value
            guard !Task.isCancelled, await permit.allowsMutation() else { return }
            await cleanSimulatorCameraInjections(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifiers: snapshot.bundleIdentifiers,
                simulatorControl: simulatorControl,
                permit: permit
            )
        }
    }

    func waitForCameraCleanup() async {
        while let task = cameraCleanupTask {
            let revision = cameraCleanupRevision
            let outcome = await SimulatorCameraCleanupWaitState().wait(
                for: task,
                timeout: simulatorCameraCleanupWaitTimeout,
                sleeper: sleeper
            )
            switch outcome {
            case .completed:
                if revision == cameraCleanupRevision { return }
            case .timedOut, .cancelled:
                task.cancel()
                cameraCleanupTask?.cancel()
                await cameraCleanupPermit.cancel()
                cameraCleanupPermit = SimulatorCameraCleanupPermit()
                cameraCleanupTask = nil
                cameraCleanupRevision &+= 1
                return
            }
        }
    }

}

func cleanSimulatorCameraInjections(
    deviceIdentifier: String,
    bundleIdentifiers: [String],
    simulatorControl: any SimulatorControlling,
    permit: SimulatorCameraCleanupPermit? = nil
) async {
    for bundleIdentifier in bundleIdentifiers {
        guard !Task.isCancelled,
              await permit?.allowsMutation() != false else { return }
        do {
            _ = try await simulatorControl.perform(.terminateApplication(
                deviceID: deviceIdentifier,
                bundleIdentifier: bundleIdentifier
            ))
        } catch is CancellationError {
            return
        } catch {}
        guard !Task.isCancelled,
              await permit?.allowsMutation() != false else { return }
        do {
            _ = try await simulatorControl.perform(.launchApplication(
                deviceID: deviceIdentifier,
                bundleIdentifier: bundleIdentifier,
                configuration: SimulatorLaunchConfiguration(
                    terminateRunningProcess: true
                )
            ))
        } catch is CancellationError {
            return
        } catch {}
    }
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
