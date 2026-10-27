import CmuxNextAgentPane

/// Records warm requests routed to a Chief host.
actor ChiefSubagentWarmHost: AgentPaneHostProviding {
    var warmed: [[String]] = []
    var ends = 0
    func endAgents() -> AcpmuxQuit.EndResult { ends += 1; return .ended }
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw ChiefSubagentReached(host: "warm") }
    func warm(sessionIds: [String]) async throws { warmed.append(sessionIds) }
}
