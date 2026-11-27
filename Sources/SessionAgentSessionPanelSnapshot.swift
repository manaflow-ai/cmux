import Foundation

struct SessionAgentSessionPanelSnapshot: Codable, Sendable {
    var rendererKind: AgentSessionRendererKind
    var providerID: AgentSessionProviderID
    var workingDirectory: String?
}
