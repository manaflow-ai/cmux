import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator Web Inspector coordinator")
struct SimulatorWebInspectorCoordinatorTests {
    @Test("Release failures report the original error to the correlated caller")
    @MainActor
    func releaseFailureIsCorrelated() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(channel: fixture.worker)
        coordinator.webInspector.currentDeviceIdentifier = "DEVICE"
        coordinator.webInspector.session = SimulatorWebInspectorSession(
            identifier: UUID(),
            target: SimulatorWebInspectorTarget(
                id: "APP|7",
                applicationIdentifier: "APP",
                pageIdentifier: 7,
                title: "Fixture",
                url: "https://example.test",
                type: "WIRTypeWebPage",
                applicationName: "Fixture",
                bundleIdentifier: nil,
                isInUse: false
            ),
            senderIdentifier: "SENDER"
        )
        let requestID = UUID()
        let generation = UUID()
        coordinator.toolOperationGenerations[.webInspector] = generation
        let responses = Task.detached {
            [try await fixture.receiveAsync(), try await fixture.receiveAsync()]
        }

        await coordinator.releaseWebInspector(
            requestIdentifier: requestID,
            operationGeneration: generation
        )

        let output = try await responses.value
        guard case .failure = output[0] else {
            Issue.record("Expected the worker-wide diagnostic")
            return
        }
        guard case let .requestFailure(responseID, failure) = output[1]
        else {
            Issue.record("Expected a correlated release failure")
            return
        }
        #expect(responseID == requestID)
        #expect(failure.code == "web_inspector_release_failed")
    }

    @Test("Target discovery reports transport failures to the correlated caller")
    @MainActor
    func discoveryFailureIsCorrelated() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(channel: fixture.worker)
        coordinator.currentDeviceIdentifier = "ATTACHED"
        let requestID = UUID()
        let generation = UUID()
        coordinator.toolOperationGenerations[.webInspector] = generation
        let responses = Task.detached {
            [try await fixture.receiveAsync(), try await fixture.receiveAsync()]
        }

        await coordinator.requestWebInspectorTargets(
            requestIdentifier: requestID,
            deviceIdentifier: "OTHER",
            operationGeneration: generation
        )

        let output = try await responses.value
        guard case .failure = output[0] else {
            Issue.record("Expected the worker-wide diagnostic")
            return
        }
        guard case let .requestFailure(responseID, failure) = output[1]
        else {
            Issue.record("Expected a correlated Web Inspector failure")
            return
        }
        #expect(responseID == requestID)
        #expect(failure.code == "web_inspector_failed")
    }
}
