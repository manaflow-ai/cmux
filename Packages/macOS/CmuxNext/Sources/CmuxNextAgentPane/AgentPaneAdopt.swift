public import Foundation

/// An outside Claude Code or Codex chat a new agent tab resumes: acpmux
/// adopts it on `session/new` (`_meta.acpmux.adopt`). The page fails closed
/// when the daemon's reply doesn't name the same `agentSessionId`.
public nonisolated struct AgentPaneAdopt: Codable, Sendable, Equatable {
    /// The acpmux harness the chat belongs to: `claude` or `codex`.
    public var harness: String
    /// The harness's own session id.
    public var agentSessionId: String

    public init(harness: String, agentSessionId: String) {
        self.harness = harness
        self.agentSessionId = agentSessionId
    }

    var reply: [String: Any] { ["harness": harness, "agentSessionId": agentSessionId] }
}
