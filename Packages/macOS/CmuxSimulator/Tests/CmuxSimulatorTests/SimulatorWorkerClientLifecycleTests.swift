import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("Discarding a worker cancels its pending graceful-exit deadline")
    func discardCancelsGracefulTerminationDeadline() async throws {
        let launcher = TestWorkerLauncher()
        let sleeper = CancellableWorkerSleeper()
        let client = makeClient(launcher: launcher, sleeper: sleeper)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))

        try await client.shutdownDevice(id: "DEVICE")
        for _ in 0..<100 {
            if await sleeper.hasStarted { break }
            await Task.yield()
        }
        #expect(endpoint.terminationCountValue() == 0)

        await client.invalidateWorker()
        for _ in 0..<100 {
            if await sleeper.wasCancelled { break }
            await Task.yield()
        }
        #expect(await sleeper.wasCancelled)
        #expect(endpoint.terminationCountValue() == 1)
        await client.stop()
    }

    @Test("Unrelated generic failures do not poison concurrent correlated requests")
    func isolatesConcurrentCorrelations() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.extendedPermissions, .cameraInjection]))
        endpoint.emit(.context(91))
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            endpoint.emit(.failure(SimulatorFailure(
                code: "unrelated_pointer_failure",
                message: "unrelated",
                isRecoverable: true
            )))
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .requestPrivacy(requestID, deviceID, bundleIdentifier):
                return .privacy(
                    requestID: requestID,
                    SimulatorPrivacySnapshot(
                        deviceID: deviceID,
                        bundleIdentifier: bundleIdentifier,
                        authorizations: [.camera: .granted]
                    )
                )
            case let .requestCameraStatus(requestID):
                return .cameraStatus(
                    requestID: requestID,
                    SimulatorCameraStatus(
                        configuration: .disabled,
                        mirrorMode: .auto,
                        injectedBundleIdentifiers: [],
                        hostCameras: []
                    )
                )
            default:
                return nil
            }
        }
        endpoint.acknowledgeRecordedPings()

        async let privacy = client.perform(.readPrivacy(
            deviceID: "DEVICE",
            bundleIdentifier: "com.example.app"
        ))
        async let camera = client.perform(.readCameraStatus)
        let (privacyResult, cameraResult) = try await (privacy, camera)

        guard case .privacy = privacyResult else {
            Issue.record("Expected correlated privacy result")
            return
        }
        guard case .cameraStatus = cameraResult else {
            Issue.record("Expected correlated camera status")
            return
        }
        await client.stop()
    }
}
