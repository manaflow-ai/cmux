import CMUXAgentLaunch
import CmuxTerminal
import Foundation

@MainActor
final class AgentGUITerminalInjector: AgentGUITerminalInjecting {
    private let promptInjector = AgentPromptInjector()

    func submitPrompt(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult {
        guard let resolved = terminalPanel(surfaceID: surfaceID) else {
            return .bindingLost
        }
        let terminalPanel = resolved.panel
        let isClaudeMultiline = (text.contains("\n") || text.contains("\r")) && TextBoxAgentDetection.isClaudeCode(
            context: WorkspaceContentView.terminalAgentContext(panel: terminalPanel, workspace: resolved.workspace)
        )
        let result = promptInjector.submit(
            text: text,
            submitKey: isClaudeMultiline ? "ctrl+enter" : "return",
            writer: AgentTerminalPanelInputWriter(panel: terminalPanel)
        )
        guard result.acceptedForAgentGUI else { return injectionResult(result) }
        terminalPanel.surface.forceRefresh(reason: "agentGUI.submitPrompt")
        return .accepted
    }

    func typeLaunchCommand(surfaceID: String, command: String) -> AgentLaunchExecutionResult {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID)?.panel else {
            return .failed("binding_lost")
        }
        let result = promptInjector.submit(
            text: command,
            submitKey: "return",
            writer: AgentTerminalPanelInputWriter(panel: terminalPanel)
        )
        if result.acceptedForAgentGUI {
            terminalPanel.surface.forceRefresh(reason: "agentLaunch.submitCommand")
        }
        return result
    }

    func sendKey(surfaceID: String, keyName: String) -> AgentGUITerminalInjectionResult {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID)?.panel else {
            return .bindingLost
        }
        let result = terminalPanel.sendNamedKeyResult(keyName)
        guard result.accepted else { return injectionResult(result) }
        terminalPanel.surface.forceRefresh(reason: "agentGUI.sendKey")
        return .accepted
    }

    func sendInput(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID)?.panel else {
            return .bindingLost
        }
        let result = terminalPanel.sendInputResult(text)
        guard result.accepted else { return injectionResult(result) }
        terminalPanel.surface.forceRefresh(reason: "agentGUI.sendInput")
        return .accepted
    }

    private func terminalPanel(surfaceID: String) -> (panel: TerminalPanel, workspace: Workspace)? {
        guard let surfaceUUID = UUID(uuidString: surfaceID),
              let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceUUID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
            return nil
        }
        guard let panel = workspace.terminalPanel(for: surfaceUUID) else { return nil }
        return (panel, workspace)
    }

    private func injectionResult(_ result: TerminalSurface.NamedKeySendResult) -> AgentGUITerminalInjectionResult {
        switch result {
        case .sent, .queued:
            .accepted
        case .inputQueueFull:
            .inputQueueFull
        case .processExited:
            .processExited
        case .unknownKey, .surfaceUnavailable:
            .bindingLost
        }
    }

    private func injectionResult(_ result: TerminalSurface.InputSendResult) -> AgentGUITerminalInjectionResult {
        switch result {
        case .sent, .queued:
            .accepted
        case .inputQueueFull:
            .inputQueueFull
        case .processExited:
            .processExited
        case .surfaceUnavailable:
            .bindingLost
        }
    }

    private func injectionResult(_ result: AgentLaunchExecutionResult) -> AgentGUITerminalInjectionResult {
        switch result {
        case .accepted, .queued:
            .accepted
        case .failed(let code):
            switch code {
            case "input_queue_full": .inputQueueFull
            case "process_exited": .processExited
            default: .bindingLost
            }
        }
    }
}

private extension AgentLaunchExecutionResult {
    var acceptedForAgentGUI: Bool {
        switch self {
        case .accepted, .queued: true
        case .failed: false
        }
    }
}
