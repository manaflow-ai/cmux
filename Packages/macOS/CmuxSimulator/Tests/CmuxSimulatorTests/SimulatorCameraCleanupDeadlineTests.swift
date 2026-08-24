import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("Activation fails while durable camera cleanup is still pending")
    func activationWaitsForCameraCleanup() async throws {
        let launcher = TestWorkerLauncher()
        let sleeper = ManualCameraCleanupDeadlineSleeper()
        let cleanupGate = PendingCameraCleanupGate()
        let client = makeClient(launcher: launcher, sleeper: sleeper)
        await client.installPendingCameraCleanup(waitingOn: cleanupGate)
        defer { Task { await cleanupGate.release() } }
        await sleeper.fireDeadline()

        do {
            try await client.activateDevice(id: "DEVICE", geometry: nil)
            Issue.record("Activation must not start while camera cleanup is pending")
        } catch let failure as SimulatorFailure {
            #expect(failure.code == "simulator_camera_cleanup_pending")
        }

        #expect(launcher.endpoint(at: 0) == nil)
        await cleanupGate.release()
    }

    @Test("Pane close timeout preserves camera cleanup through its late relaunch")
    func cameraCleanupCloseDeadline() async throws {
        let deviceIdentifier = "CAMERA-DEADLINE-\(UUID().uuidString)"
        let bundleIdentifier = "com.example.camera-deadline"
        let launcher = TestWorkerLauncher()
        let control = BlockingCameraCleanupDeadlineControl()
        let sleeper = ManualCameraCleanupDeadlineSleeper()
        let client = makeClient(
            launcher: launcher,
            control: control,
            sleeper: sleeper
        )
        await client.send(.attach(udid: deviceIdentifier, geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        let readiness = await client.subscribe()
        var readinessIterator = readiness.makeAsyncIterator()
        endpoint.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .configureCamera(requestID, configuration):
                return .cameraConfiguration(
                    requestID: requestID,
                    succeeded: true,
                    targetBundleIdentifier: configuration.targetBundleIdentifier
                )
            default:
                return nil
            }
        }
        endpoint.acknowledgeRecordedPings()
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.cameraInjection]))
        endpoint.emit(.frameTransport(simulatorFrameTransportDescriptor(79)))
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        _ = try await client.perform(.configureCamera(.targeted(
            bundleIdentifier: bundleIdentifier,
            source: .placeholder
        )))

        let stopProbe = CameraCleanupStopProbe()
        let stop = Task {
            await client.stop()
            await stopProbe.finish()
        }
        await control.waitUntilBlocked()
        #expect(await control.isBlocked)

        await sleeper.fireDeadline()
        await stopProbe.waitUntilFinished()
        #expect(await stopProbe.didFinish)

        await control.release()
        await stop.value
        await control.waitUntilBlockedCallReturns()
        for _ in 0..<2_000 {
            if await control.actions.count == 1 { break }
            await Task.yield()
        }
        #expect(await control.blockedCallReturned)
        let actions = await control.actions
        guard case let .cleanupCameraApplication(deviceID, target, _) = actions.first else {
            Issue.record("Expected one durable camera cleanup action")
            return
        }
        #expect(deviceID == deviceIdentifier)
        #expect(target == bundleIdentifier)
    }
}

private actor PendingCameraCleanupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private extension SimulatorWorkerClient {
    func installPendingCameraCleanup(waitingOn gate: PendingCameraCleanupGate) {
        cameraCleanupRevision &+= 1
        cameraCleanupTask = Task {
            await gate.wait()
            return .completed
        }
    }
}
