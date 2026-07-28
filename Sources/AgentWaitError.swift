enum AgentWaitError: Error, Sendable, Equatable {
    case surfaceNotFound
    case noAgent
    case subscriptionClosed(String?)
}
