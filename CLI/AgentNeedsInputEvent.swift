struct AgentNeedsInputEvent {
    let agentKind: String
    let statusKey: String
    let title: String
    let workspaceId: String
    let surfaceId: String
    let sessionId: String?
    let subtitle: String
    let body: String
    let dedupKey: String?
    let sourceSignal: AgentNeedsInputSourceSignal
}
