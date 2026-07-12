import CmuxTerminal
import Foundation

@MainActor
final class AgentGUITerminalInjector: AgentGUITerminalInjecting {
    func submitPrompt(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult {
        guard let resolved = terminalPanel(surfaceID: surfaceID) else {
            return .bindingLost
        }
        let terminalPanel = resolved.panel
        for keyName in ["ctrl+a", "ctrl+k", "ctrl+u"] {
            let result = terminalPanel.sendNamedKeyResult(keyName)
            guard result.accepted else { return injectionResult(result) }
        }
        guard terminalPanel.sendText(text) else {
            return .bindingLost
        }
        let isClaudeMultiline = (text.contains("\n") || text.contains("\r")) && TextBoxAgentDetection.isClaudeCode(
            context: WorkspaceContentView.terminalAgentContext(panel: terminalPanel, workspace: resolved.workspace)
        )
        let submitResult = terminalPanel.sendNamedKeyResult(isClaudeMultiline ? "ctrl+enter" : "return")
        guard submitResult.accepted else { return injectionResult(submitResult) }
        terminalPanel.surface.forceRefresh(reason: "agentGUI.submitPrompt")
        return .accepted
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
}
