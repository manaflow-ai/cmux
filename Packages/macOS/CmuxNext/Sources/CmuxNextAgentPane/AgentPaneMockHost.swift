import Foundation

/// No daemon: the page runs its in-memory mock transcript (demos, tests,
/// `CMUX_NEXT_AGENT_PANE_MOCK=1`).
public nonisolated struct MockAgentPaneHost: AgentPaneHostProviding {
    public init() {}

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
}
