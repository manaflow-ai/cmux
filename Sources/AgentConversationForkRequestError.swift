enum AgentConversationForkRequestError: Error, Equatable {
    case targetExecutableChanged
    case targetExecutableUnverified
}
