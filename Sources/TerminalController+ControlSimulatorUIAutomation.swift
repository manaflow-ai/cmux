import CmuxControlSocket
import CmuxSimulatorUI
import CmuxSimulatorUIAutomation

extension TerminalController {
    func performSimulatorUIAutomationOperation(
        _ operation: ControlSimulatorOperation,
        coordinator: SimulatorPaneCoordinator
    ) async throws -> JSONValue {
        try await SimulatorUIAutomationExecutor().perform(
            operation,
            coordinator: coordinator
        )
    }
}
