import Foundation

struct SessionAgentSessionPanelSnapshot: Codable, Sendable {
    var rendererKind: AgentSessionRendererKind
    var providerID: AgentSessionProviderID
    var workingDirectory: String?
    var guiModePage: GuiModePanelPage? = nil
    var guiModePrompt: String? = nil
    var guiModeProviderID: GuiModeProviderID? = nil
}
