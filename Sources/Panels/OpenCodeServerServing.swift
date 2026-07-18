protocol OpenCodeServerServing: Sendable {
    func acquireConnection(plan: AgentSessionLaunchPlan) async throws -> OpenCodeServerConnection
    func releaseConnection() async
    func terminateImmediately()
}
