enum AgentLifecyclePublicState: String, Sendable, Equatable {
    case unknown
    case running
    case idle
    case needsInput = "needs-input"
    case exit

    init(_ lifecycle: AgentHibernationLifecycleState) {
        switch lifecycle {
        case .unknown:
            self = .unknown
        case .running:
            self = .running
        case .idle:
            self = .idle
        case .needsInput:
            self = .needsInput
        }
    }
}
