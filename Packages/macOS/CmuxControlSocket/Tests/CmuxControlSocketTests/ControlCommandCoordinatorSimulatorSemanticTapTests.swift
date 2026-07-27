import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator Simulator semantic taps")
struct ControlCommandCoordinatorSimulatorSemanticTapTests {
    @Test("Accessibility selectors route as one correlated operation")
    func selectorTap() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object(["completed": .bool(true)])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        guard case .ok = coordinator.handleSocketWorkerV2(
            request("simulator.tap", [
                "label": .string("General"),
                "identifier": .string("com.apple.settings.general"),
                "role": .string("button"),
            ]),
            context: context
        ) else {
            Issue.record("Expected correlated semantic tap success")
            return
        }

        #expect(context.lastOperation == .accessibilityTap(
            label: "General",
            identifier: "com.apple.settings.general",
            role: "button"
        ))
        #expect(context.lastOperation?.commitsExternalMutation == true)
    }

    @Test("Coordinate and accessibility tap inputs cannot be mixed")
    func mixedTapInputs() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
            request("simulator.tap", [
                "x": .double(0.5), "y": .double(0.5), "label": .string("General"),
            ]),
            context: context
        ) else {
            Issue.record("Expected mixed-input rejection")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.lastOperation == nil)
    }

    @Test("Role alone is not a unique accessibility selector")
    func roleOnlyTap() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        guard case let .err(code, _, _) = coordinator.handleSocketWorkerV2(
            request("simulator.tap", ["role": .string("button")]),
            context: context
        ) else {
            Issue.record("Expected incomplete-selector rejection")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.lastOperation == nil)
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}
