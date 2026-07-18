/// Identifies one immutable daemon lifetime and its persisted logical session.
public struct BackendAuthority: Codable, Equatable, Sendable {
    /// The identifier that changes whenever the daemon process restarts.
    public let daemonInstanceID: DaemonInstanceID

    /// The identifier that survives daemon restarts for the same logical session.
    public let sessionID: SessionID

    /// Creates a backend authority fence.
    ///
    /// - Parameters:
    ///   - daemonInstanceID: The identifier for the current daemon lifetime.
    ///   - sessionID: The identifier for the persisted logical session.
    public init(daemonInstanceID: DaemonInstanceID, sessionID: SessionID) {
        self.daemonInstanceID = daemonInstanceID
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
    }
}
