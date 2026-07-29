enum AgentWaitError: Error, Sendable, Equatable {
    case surfaceNotFound
    case noAgent
    case liveLifecycleUnavailable
    case subscriptionClosed
}
