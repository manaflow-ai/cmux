import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("Simulator event-log control")
struct ControlCommandCoordinatorSimulatorEventLogTests {
    @Test("Defaults to five hundred events and rejects larger requests")
    func boundedHistory() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object([:])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        _ = coordinator.handleSocketWorkerV2(request(limit: nil), context: context)
        #expect(context.lastOperation == .eventLog(limit: 500))
        _ = coordinator.handleSocketWorkerV2(request(limit: 500), context: context)
        #expect(context.lastOperation == .eventLog(limit: 500))
        guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
            request(limit: 501), context: context
        ) else {
            Issue.record("Expected an invalid event-log limit error")
            return
        }
        #expect(code == "invalid_params")
    }

    private func request(limit: Int?) -> ControlRequest {
        ControlRequest(
            id: .int(1),
            method: "simulator.event_log",
            params: limit.map { ["limit": .int(Int64($0))] } ?? [:]
        )
    }
}
