import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("Pane close times out blocked camera cleanup without a late relaunch")
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
        #expect(await control.blockedCallReturned)
        #expect(await control.actions == [
            .terminateApplication(
                deviceID: deviceIdentifier,
                bundleIdentifier: bundleIdentifier
            ),
        ])
    }
}
