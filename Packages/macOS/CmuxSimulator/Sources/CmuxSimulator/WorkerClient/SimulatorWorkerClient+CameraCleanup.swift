import Foundation

struct SimulatorCameraCleanupSnapshot: Sendable {
    let deviceIdentifier: String?
    let bundleIdentifiers: [String]
}

extension SimulatorWorkerClient {
    nonisolated static let cameraCleanupWaitTimeout: Duration = .seconds(3)

    func cameraCleanupSnapshot() -> SimulatorCameraCleanupSnapshot {
        SimulatorCameraCleanupSnapshot(
            deviceIdentifier: Self.attachedDeviceIdentifier(from: lastAttachment),
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
            await Self.cleanCameraInjections(
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
                timeout: Self.cameraCleanupWaitTimeout,
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

    nonisolated static func cleanCameraInjections(
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

    nonisolated static func attachedDeviceIdentifier(
        from attachment: SimulatorWorkerInbound?
    ) -> String? {
        guard case let .attach(deviceIdentifier, _) = attachment else { return nil }
        return deviceIdentifier
    }

    nonisolated static func unlinkCameraSharedMemory(
        connection: SimulatorWorkerConnection,
        deviceIdentifier: String?
    ) {
        guard let deviceIdentifier,
              let processIdentifier = connection.processIdentifier,
              processIdentifier > 1 else { return }
        SimulatorCameraSharedMemory(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: processIdentifier
        ).unlink()
    }
}
