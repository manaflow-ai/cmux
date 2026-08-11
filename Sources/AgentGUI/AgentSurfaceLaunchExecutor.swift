import CMUXAgentLaunch
import Foundation

@MainActor
final class AgentSurfaceLaunchExecutor: AgentLaunchExecuting {
    private let service: AgentGUIService
    private let terminalInjector: AgentGUITerminalInjector

    init(
        service: AgentGUIService,
        terminalInjector: AgentGUITerminalInjector? = nil
    ) {
        self.service = service
        self.terminalInjector = terminalInjector ?? AgentGUITerminalInjector()
    }

    func typeLaunchCommand(surfaceID: String, command: String) -> AgentLaunchExecutionResult {
        terminalInjector.typeLaunchCommand(surfaceID: surfaceID, command: command)
    }

    func submitPrompt(surfaceID: String, text: String, ticketID: UUID?) -> AgentLaunchExecutionResult {
        service.submitCmuxOwnedPrompt(surfaceID: surfaceID, text: text, ticketID: ticketID)
    }
}
