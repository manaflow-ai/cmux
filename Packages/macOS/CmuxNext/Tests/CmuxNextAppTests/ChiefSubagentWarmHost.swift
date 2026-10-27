import CmuxNextAgentPane

/// Records warm requests routed to a Chief host.
actor ChiefSubagentWarmHost: AgentPaneHostProviding {
    var warmed: [[String]] = []
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw ChiefSubagentReached(host: "warm") }
    func warm(sessionIds: [String]) async throws { warmed.append(sessionIds) }
}
