import Foundation

public enum AgentState: String, Sendable, Hashable, Codable {
    case working, blocked, idle, done, unknown
}

/// `AgentStatus` is generated from the schema's `AgentRecord` (swift_app/bindings.json, Agents family).

extension AgentStatus {
    /// The harness session this agent runs (`claude`, `codex` session id): a hook report's
    /// `agentSessionID`, else a direct report's `session`. Hook bookkeeping markers
    /// (`cmux-hook-…`) are none. Copy Session ID and `cmux://agent` links read it.
    public var harnessSessionID: String? {
        guard let id = agentSessionID ?? session, !id.isEmpty, !id.hasPrefix("cmux-hook-") else { return nil }
        return id
    }
}
