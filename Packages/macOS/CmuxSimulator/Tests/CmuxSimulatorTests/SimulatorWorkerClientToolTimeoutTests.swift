import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("A camera request timeout restarts the isolated worker")
    func cameraRequestTimeoutRestartsWorker() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(
            launcher: launcher,
            sleeper: OneShotCameraRequestTimeoutSleeper()
        )
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.cameraInjection]))
        endpoint.emit(.frameTransport(simulatorFrameTransportDescriptor(16)))
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        endpoint.acknowledgeRecordedPings()

        do {
            _ = try await client.perform(.configureCamera(.placeholder))
            Issue.record("Expected the bounded camera timeout")
        } catch let error as SimulatorControlError {
            #expect(error.code == "worker_response_timed_out")
        }

        #expect(endpoint.terminationCountValue() == 1)
        #expect(launcher.endpoint(at: 1) != nil)
        await client.stop()
    }
}

private actor OneShotCameraRequestTimeoutSleeper: SimulatorWorkerSleeping {
    private var deliveredTimeout = false

    func sleep(for duration: Duration) async throws {
        if duration == .seconds(120), !deliveredTimeout {
            deliveredTimeout = true
            return
        }
        try await ContinuousClock().sleep(for: .seconds(3_600))
    }
}
