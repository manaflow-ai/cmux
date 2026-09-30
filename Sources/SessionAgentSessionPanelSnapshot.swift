import Foundation

struct SessionAgentSessionPanelSnapshot: Codable, Sendable {
    var rendererKind: AgentSessionRendererKind
    var providerID: AgentSessionProviderID
    var workingDirectory: String?
    /// The acpmux session the chat pane showed. Absent in snapshots from the web renderer.
    var acpmuxSessionId: String?
}
