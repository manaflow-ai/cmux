public import CmuxAgentReplica

/// Parameters for requesting one agent session.
public struct GuiSessionParams: Codable, Hashable, Sendable {
    /// The requested session identifier.
    public let sessionID: AgentSessionID

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }

    /// Creates a session request.
    /// - Parameter sessionID: The requested session identifier.
    public init(sessionID: AgentSessionID) {
        self.sessionID = sessionID
    }
}

/// Result containing one whole-value agent session snapshot.
public struct GuiSessionResult: Codable, Hashable, Sendable {
    /// The epoch that scopes the returned snapshot.
    public let epoch: ReplicaEpoch
    /// The requested whole-value session snapshot.
    public let session: AgentSessionSnapshot

    /// Creates a session result.
    /// - Parameters:
    ///   - epoch: The epoch that scopes the snapshot.
    ///   - session: The requested session snapshot.
    public init(epoch: ReplicaEpoch, session: AgentSessionSnapshot) {
        self.epoch = epoch
        self.session = session
    }
}
