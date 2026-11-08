import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Simulator accessibility worker client")
struct SimulatorAccessibilityWorkerClientTests {
    @Test("Accessibility read waits for its matching worker response")
    func accessibilityCorrelation() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.accessibility]))
        endpoint.emit(.frameTransport(simulatorFrameTransportDescriptor(12)))
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .requestAccessibility(requestID):
                return .accessibility(
                    requestID: requestID,
                    SimulatorAccessibilitySnapshot(
                        roots: [SimulatorAccessibilityNode(
                            id: "button",
                            role: "Button",
                            label: "Continue",
                            value: nil,
                            roleDescription: "button",
                            frame: SimulatorRect(x: 10, y: 20, width: 80, height: 40),
                            isEnabled: true,
                            children: []
                        )],
                        display: Self.display,
                        nodeCount: 1
                    )
                )
            default:
                return nil
            }
        }
        endpoint.acknowledgeRecordedPings()

        let result = try await client.perform(.readAccessibility)

        guard case let .accessibility(snapshot) = result else {
            Issue.record("Expected a correlated accessibility snapshot")
            return
        }
        #expect(snapshot.nodeCount == 1)
        #expect(snapshot.roots.first?.label == "Continue")
        await client.stop()
    }

    @Test("A nil foreground app is a correlated value, not a timeout")
    func nilForegroundCorrelation() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.foregroundApplication]))
        endpoint.emit(.frameTransport(simulatorFrameTransportDescriptor(13)))
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .requestForegroundApplication(requestID):
                return .foregroundApplication(requestID: requestID, nil)
            default:
                return nil
            }
        }
        endpoint.acknowledgeRecordedPings()

        let result = try await client.perform(.readForegroundApplication)

        #expect(result == .foregroundApplication(nil))
        await client.stop()
    }

    @Test("A correlated accessibility failure keeps the healthy worker generation alive")
    func correlatedFailureDoesNotTripTimeoutRecovery() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.accessibility]))
        endpoint.emit(.frameTransport(simulatorFrameTransportDescriptor(14)))
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .requestAccessibility(requestID):
                return .requestFailure(
                    requestID: requestID,
                    SimulatorFailure(
                        code: "accessibility_unavailable",
                        message: "Fixture unavailable",
                        isRecoverable: true
                    )
                )
            default:
                return nil
            }
        }
        endpoint.acknowledgeRecordedPings()

        do {
            _ = try await client.perform(.readAccessibility)
            Issue.record("Expected the correlated worker failure")
        } catch let failure as SimulatorFailure {
            #expect(failure.code == "accessibility_unavailable")
        }
        #expect(launcher.endpoint(at: 1) == nil)
        await client.stop()
    }

    @Test("A foreground telemetry timeout restarts the isolated worker")
    func foregroundTimeoutRestartsWorker() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(
            launcher: launcher,
            sleeper: ForegroundTimeoutSleeper()
        )
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.foregroundApplication]))
        endpoint.emit(.frameTransport(simulatorFrameTransportDescriptor(15)))
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        endpoint.acknowledgeRecordedPings()

        do {
            _ = try await client.perform(.readForegroundApplication)
            Issue.record("Expected the bounded foreground timeout")
        } catch let error as SimulatorControlError {
            #expect(error.code == "worker_response_timed_out")
        }

        #expect(endpoint.terminationCountValue() == 1)
        #expect(launcher.endpoint(at: 1) != nil)
        await client.stop()
    }

    private func makeClient(
        launcher: TestWorkerLauncher,
        sleeper: any SimulatorWorkerSleeping = ContinuousSimulatorWorkerSleeper()
    ) -> SimulatorWorkerClient {
        SimulatorWorkerClient(
            executableURL: URL(fileURLWithPath: "/fake/cmux"),
            arguments: [SimulatorWorkerClient.workerModeArgument],
            environment: [:],
            ackTimeout: .seconds(60),
            replayTimeout: .seconds(120),
            simulatorControl: TestSimulatorControl(),
            launcher: launcher,
            sleeper: sleeper
        )
    }

    private static let display = SimulatorDisplayMetadata(
        width: 1_200,
        height: 2_400,
        orientation: .portrait,
        scale: 3
    )
}
