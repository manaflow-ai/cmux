import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator Simulator reads")
struct ControlCommandCoordinatorSimulatorReadTests {
    @Test("Accessibility and foreground reads use correlated Simulator operations")
    func accessibilityAndForegroundOperations() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object(["node_count": .int(75)])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        guard case let .ok(.object(accessibility)) = coordinator.handleSocketWorkerV2(
            request("simulator.accessibility"), context: context
        ) else {
            Issue.record("Expected accessibility payload")
            return
        }
        #expect(context.lastOperation == .accessibility)
        #expect(accessibility["node_count"] == .int(75))

        let foregroundReceipt = ControlSimulatorOperationReceipt()
        foregroundReceipt.complete(.success(.object([
            "application": .object(["bundle_id": .string("com.example.App")]),
        ])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: foregroundReceipt
        )
        _ = coordinator.handleSocketWorkerV2(
            request("simulator.foreground"), context: context
        )
        #expect(context.lastOperation == .foregroundApplication)
    }

    @Test("Simulator context returns the selected pane identity")
    func simulatorContext() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object([
            "simulator_id": .string("SIM-UDID"),
            "device_name": .string("iPhone Air"),
        ])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        guard case let .ok(.object(payload)) = coordinator.handleSocketWorkerV2(
            request("simulator.context"), context: context
        ) else {
            Issue.record("Expected Simulator context payload")
            return
        }
        #expect(context.lastOperation == .context)
        #expect(payload["simulator_id"] == .string("SIM-UDID"))
        #expect(payload["device_name"] == .string("iPhone Air"))
    }

    @Test("Screenshot preparation uses a mutating capture-readiness operation")
    func simulatorScreenshotPreparation() {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let receipt = ControlSimulatorOperationReceipt()
        receipt.complete(.success(.object([
            "simulator_id": .string("SIM-UDID"),
        ])))
        context.operationResolution = .started(
            surfaceID: UUID(), timeoutSeconds: 1, receipt: receipt
        )

        guard case .ok = coordinator.handleSocketWorkerV2(
            request("simulator.prepare_screenshot"), context: context
        ) else {
            Issue.record("Expected screenshot preparation payload")
            return
        }
        #expect(context.lastOperation == .prepareScreenshot)
        #expect(context.lastOperation?.commitsExternalMutation == true)
    }

    @Test("Permission and interface methods stay on the bounded socket worker")
    func settingsExecutionPolicy() {
        for method in [
            "simulator.context", "simulator.prepare_screenshot",
            "simulator.permissions.read", "simulator.permissions.set",
            "simulator.ui.status", "simulator.ui.set",
        ] {
            #expect(
                ControlCommandExecutionPolicy(forMethod: method)
                    == .socketWorker(mainThreadCallable: false),
                "\(method)"
            )
        }
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}
