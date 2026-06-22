import Foundation

struct SessionAgentSessionPanelSnapshot: Codable, Sendable {
    var rendererKind: AgentSessionRendererKind
    var providerID: AgentSessionProviderID
    var modelID: String? = nil
    var openCodeProviderID: String? = nil
    var providerSelectionID: String? = nil
    var workingDirectory: String?
}
