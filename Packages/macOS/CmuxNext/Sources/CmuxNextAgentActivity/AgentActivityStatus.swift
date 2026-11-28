import Foundation

/// How the host learned which agent drives a session, strongest first.
public nonisolated enum AgentActivityAttribution: String, Sendable, Hashable {
    case credential
    case processTree = "process_tree"
    case none
}

/// Why a session ended.
public nonisolated enum AgentActivityEndReason: String, Sendable, Hashable {
    case agentEnd = "agent_end"
    case idleTTL = "idle_ttl"
    case userStop = "user_stop"
    case hostRestart = "host_restart"
    case policy
}

public nonisolated enum AgentActivityStatus: Sendable, Hashable {
    case active
    case idle
    case paused
    case ended(AgentActivityEndReason)

    public var isLive: Bool {
        if case .ended = self { return false }
        return true
    }
}
