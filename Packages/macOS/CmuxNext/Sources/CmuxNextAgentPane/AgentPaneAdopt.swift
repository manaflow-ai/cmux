public import Foundation

/// An outside Claude Code or Codex chat a new agent tab resumes: acpmux
/// adopts it on `session/new` (`_meta.acpmux.adopt`). The page fails closed
/// when the daemon's reply doesn't name the same `agentSessionId`.
public nonisolated struct AgentPaneAdopt: Codable, Sendable, Equatable {
    /// The acpmux harness the chat belongs to: `claude` or `codex`.
    public var harness: String
    /// The harness's own session id.
    public var agentSessionId: String
    /// View Only: the tab shows the chat and follows the app that runs it without running it,
    /// until Take Over (acpmux `hub/watch.rs`). Absent for a chat the tab runs.
    public var watch: Bool?

    public init(harness: String, agentSessionId: String, watch: Bool? = nil) {
        self.harness = harness
        self.agentSessionId = agentSessionId
        self.watch = watch
    }

    var reply: [String: Any] {
        var reply: [String: Any] = ["harness": harness, "agentSessionId": agentSessionId]
        if watch == true { reply["watch"] = true }
        return reply
    }
}
