import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Web Inspector worker client")
struct SimulatorWebInspectorWorkerClientTests {
    @Test("Targets, attachment, commands, and release use correlated worker messages")
    func correlatedActions() async throws {
        let launcher = TestWorkerLauncher()
        let client = SimulatorWorkerClient(
            executableURL: URL(fileURLWithPath: "/fake/cmux"),
            arguments: [SimulatorWorkerClient.workerModeArgument],
            environment: [:],
            ackTimeout: .seconds(60),
            simulatorControl: TestSimulatorControl(),
            launcher: launcher,
            sleeper: ContinuousSimulatorWorkerSleeper()
        )
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.webInspector]))
        _ = await iterator.next()
        _ = await iterator.next()
        let target = Self.target()
        endpoint.setResponder { message in
            switch message {
            case let .ping(sequence):
                .ack(sequence)
            case let .requestWebInspectorTargets(requestID, _):
                .webInspectorTargets(requestID: requestID, [target])
            case let .attachWebInspector(requestID, _):
                .webInspectorSession(
                    requestID: requestID,
                    .attached(sessionID: UUID(), targetID: target.id)
                )
            case let .sendWebInspectorMessage(requestID, _):
                .webInspectorCommand(requestID: requestID, accepted: true)
            case let .releaseWebInspector(requestID):
                .webInspectorSession(requestID: requestID, .detached)
            default:
                nil
            }
        }
        endpoint.acknowledgeRecordedPings()

        #expect(try await client.perform(.refreshWebInspectorTargets(deviceID: "DEVICE"))
            == .webInspectorTargets([target]))
        guard case .webInspectorSession(.attached) = try await client.perform(
            .attachWebInspector(targetID: target.id)
        ) else {
            Issue.record("Expected an attached inspector session")
            return
        }
        #expect(try await client.perform(.sendWebInspectorMessage(json: "{\"id\":1}")) == .none)
        #expect(try await client.perform(.releaseWebInspector) == .webInspectorSession(.detached))
        await client.stop()
    }

    private static func target() -> SimulatorWebInspectorTarget {
        SimulatorWebInspectorTarget(
            id: "APP|1",
            applicationIdentifier: "APP",
            pageIdentifier: 1,
            title: "Fixture",
            url: "https://example.test",
            type: "WIRTypeWebPage",
            applicationName: "Example",
            bundleIdentifier: "com.example.app",
            isInUse: false
        )
    }
}
