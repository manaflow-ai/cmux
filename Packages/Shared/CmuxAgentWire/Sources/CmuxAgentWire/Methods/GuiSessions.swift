public import CmuxAgentReplica

/// Parameters for requesting all current agent sessions.
public struct GuiSessionsParams: Codable, Hashable, Sendable {
    /// Creates an empty sessions request.
    public init() {}
}

/// Pull-authoritative result containing all current agent sessions.
public struct GuiSessionsResult: Codable, Hashable, Sendable {
    /// The epoch that scopes the returned snapshots.
    public let epoch: ReplicaEpoch
    /// Whole-value session snapshots.
    public let sessions: [AgentSessionSnapshot]

    /// Creates a sessions result.
    /// - Parameters:
    ///   - epoch: The epoch that scopes the snapshots.
    ///   - sessions: Whole-value session snapshots.
    public init(epoch: ReplicaEpoch, sessions: [AgentSessionSnapshot]) {
        self.epoch = epoch
        self.sessions = sessions
    }
}
