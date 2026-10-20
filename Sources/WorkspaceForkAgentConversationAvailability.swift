enum WorkspaceForkAgentConversationAvailability: Equatable, Sendable {
    case available
    case notTerminalPanel
    case noAgentSnapshot
    case agentIndexRefreshing
    case unsupported
    case requiresProbe

    var isAvailable: Bool {
        self == .available
    }

    var diagnosticReason: String {
        switch self {
        case .available:
            return "available"
        case .notTerminalPanel:
            return "not_terminal_panel"
        case .noAgentSnapshot:
            return "no_agent_snapshot"
        case .agentIndexRefreshing:
            return "agent_index_refreshing"
        case .unsupported:
            return "unsupported"
        case .requiresProbe:
            return "requires_probe"
        }
    }
}
