import Foundation

/// A bounded, non-transcript summary of one live workspace advertised through the device registry.
public struct CmxLiveSession: Codable, Identifiable, Sendable, Equatable {
    /// The stable registry row identifier. This is the workspace identifier.
    public let id: String
    /// The live workspace to select after attaching to the runtime.
    public let workspaceID: String
    /// The terminal hosting the preferred agent session, when one is known.
    public let terminalID: String?
    /// The preferred agent's own session identifier, when one is known.
    public let agentSessionID: String?
    /// The user-facing workspace title, which may be user-authored or terminal-derived.
    public let title: String
    /// The agent runtime identifier, such as `codex` or `claude`.
    public let agent: String?
    /// The workspace or preferred agent's current status.
    public let status: CmxLiveSessionStatus
    /// Unix epoch seconds for the most recent workspace or agent activity.
    public let lastActivityAt: TimeInterval

    /// Creates a registry-safe live session summary.
    ///
    /// - Parameters:
    ///   - id: Stable registry row identifier.
    ///   - workspaceID: Workspace selected after attach.
    ///   - terminalID: Preferred agent terminal, when known.
    ///   - agentSessionID: Preferred agent session, when known.
    ///   - title: User-facing workspace title, which may be terminal-derived.
    ///   - agent: Agent runtime identifier, when known.
    ///   - status: Current workspace or agent status.
    ///   - lastActivityAt: Unix epoch seconds of the latest activity.
    public init(
        id: String,
        workspaceID: String,
        terminalID: String? = nil,
        agentSessionID: String? = nil,
        title: String,
        agent: String? = nil,
        status: CmxLiveSessionStatus,
        lastActivityAt: TimeInterval
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.agentSessionID = agentSessionID
        self.title = title
        self.agent = agent
        self.status = status
        self.lastActivityAt = lastActivityAt
    }

}
