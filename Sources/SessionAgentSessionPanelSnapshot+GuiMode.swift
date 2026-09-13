import Foundation

@MainActor
extension SessionAgentSessionPanelSnapshot {
    init(agentPanel: AgentSessionPanel, workingDirectory: String?) {
        self.init(
            rendererKind: agentPanel.rendererKind,
            providerID: agentPanel.currentProviderID,
            workingDirectory: workingDirectory,
            guiModePage: agentPanel.guiModePage,
            guiModePrompt: agentPanel.guiModePrompt,
            guiModeProviderID: agentPanel.guiModeProviderID,
            guiModeModelID: agentPanel.guiModeState.modelID,
            guiModeReasoningEffort: agentPanel.guiModeState.reasoningEffort
        )
    }
}
