import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator Web Inspector coordinator")
struct SimulatorWebInspectorCoordinatorTests {
    @Test("Target discovery reports transport failures to the correlated caller")
    @MainActor
    func discoveryFailureIsCorrelated() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(channel: fixture.worker)
        coordinator.currentDeviceIdentifier = "ATTACHED"
        let requestID = UUID()
        let generation = UUID()
        coordinator.toolOperationGenerations[.webInspector] = generation

        await coordinator.requestWebInspectorTargets(
            requestIdentifier: requestID,
            deviceIdentifier: "OTHER",
            operationGeneration: generation
        )

        guard case .failure = try await fixture.receiveAsync() else {
            Issue.record("Expected the worker-wide diagnostic")
            return
        }
        guard case let .requestFailure(responseID, failure) = try await fixture.receiveAsync()
        else {
            Issue.record("Expected a correlated Web Inspector failure")
            return
        }
        #expect(responseID == requestID)
        #expect(failure.code == "web_inspector_failed")
    }
}
