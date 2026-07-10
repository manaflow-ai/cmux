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
        endpoint.emit(.capabilities([.accessibility]))
        endpoint.emit(.context(12))
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            guard case let .requestAccessibility(requestID) = message else { return nil }
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
        }

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
        endpoint.emit(.capabilities([.foregroundApplication]))
        endpoint.emit(.context(13))
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            guard case let .requestForegroundApplication(requestID) = message else { return nil }
            return .foregroundApplication(requestID: requestID, nil)
        }

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
        endpoint.emit(.capabilities([.accessibility]))
        endpoint.emit(.context(14))
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            guard case let .requestAccessibility(requestID) = message else { return nil }
            return .requestFailure(
                requestID: requestID,
                SimulatorFailure(
                    code: "accessibility_unavailable",
                    message: "Fixture unavailable",
                    isRecoverable: true
                )
            )
        }

        do {
            _ = try await client.perform(.readAccessibility)
            Issue.record("Expected the correlated worker failure")
        } catch let failure as SimulatorFailure {
            #expect(failure.code == "accessibility_unavailable")
        }
        #expect(launcher.endpoint(at: 1) == nil)
        await client.stop()
    }

    private func makeClient(launcher: TestWorkerLauncher) -> SimulatorWorkerClient {
        SimulatorWorkerClient(
            executableURL: URL(fileURLWithPath: "/fake/cmux"),
            arguments: [SimulatorWorkerClient.workerModeArgument],
            environment: [:],
            ackTimeout: .seconds(60),
            replayTimeout: .seconds(120),
            simulatorControl: TestSimulatorControl(),
            launcher: launcher,
            sleeper: ContinuousSimulatorWorkerSleeper()
        )
    }

    private static let display = SimulatorDisplayMetadata(
        width: 1_200,
        height: 2_400,
        orientation: .portrait,
        scale: 3
    )
}
