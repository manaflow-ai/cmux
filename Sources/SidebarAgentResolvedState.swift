import CmuxWorkspaces

/// Confidence-aware agent state rendered by the workspace sidebar.
enum SidebarAgentResolvedState: String, Equatable, Sendable {
    case running
    case needsInput
    case idle
    case unknown

    init(
        lifecycle: AgentHibernationLifecycleState?,
        processLiveness: RestorableAgentProcessLiveness,
        hasExactProcessIdentity: Bool,
        hasLiveLifecycleSignal: Bool,
        hasDeterministicSignal: Bool
    ) {
        guard hasDeterministicSignal else {
            self = .unknown
            return
        }
        switch lifecycle {
        case .running:
            if processLiveness == .exited {
                self = .unknown
            } else if processLiveness == .running
                        || hasExactProcessIdentity
                        || hasLiveLifecycleSignal {
                self = .running
            } else {
                self = .unknown
            }
        case .needsInput:
            if processLiveness == .exited {
                self = .unknown
            } else if processLiveness == .running
                        || hasExactProcessIdentity
                        || hasLiveLifecycleSignal {
                self = .needsInput
            } else {
                self = .unknown
            }
        case .idle:
            self = processLiveness == .exited ? .unknown : .idle
        case .unknown, nil:
            self = .unknown
        }
    }
}
