/// Lightweight authority proof returned by the backend `ping` command.
public struct BackendHealthResponse: Codable, Equatable, Sendable {
    /// The backend's diagnostic build version.
    public let version: String

    /// The backend's preferred protocol version.
    public let protocolVersion: UInt32

    /// The oldest protocol version accepted by the backend.
    public let protocolMinimum: UInt32

    /// The newest protocol version accepted by the backend.
    public let protocolMaximum: UInt32

    /// Capabilities active on the running backend.
    public let capabilities: Set<String>

    /// The logical app-scoped session name.
    public let session: String

    /// The daemon-lifetime and persisted-session identity fence.
    public let authority: BackendAuthority

    /// The structural topology revision, without the topology payload.
    public let canonicalTopologyRevision: UInt64

    /// The operating-system process identifier reported by the backend.
    public let processID: UInt32

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case protocolMinimum = "protocol_min"
        case protocolMaximum = "protocol_max"
        case capabilities
        case session
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case canonicalTopologyRevision = "canonical_topology_revision"
        case processID = "pid"
    }

    /// Decodes one lightweight health response.
    ///
    /// - Parameter decoder: The decoder containing the ping payload.
    /// - Throws: Any error raised while decoding required authority fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        protocolVersion = try container.decode(UInt32.self, forKey: .protocolVersion)
        protocolMinimum = try container.decode(UInt32.self, forKey: .protocolMinimum)
        protocolMaximum = try container.decode(UInt32.self, forKey: .protocolMaximum)
        capabilities = Set(try container.decode([String].self, forKey: .capabilities))
        session = try container.decode(String.self, forKey: .session)
        authority = BackendAuthority(
            daemonInstanceID: try container.decode(DaemonInstanceID.self, forKey: .daemonInstanceID),
            sessionID: try container.decode(SessionID.self, forKey: .sessionID)
        )
        canonicalTopologyRevision = try container.decode(
            UInt64.self,
            forKey: .canonicalTopologyRevision
        )
        processID = try container.decode(UInt32.self, forKey: .processID)
    }

    /// Encodes one lightweight health response.
    ///
    /// - Parameter encoder: The encoder receiving the ping payload.
    /// - Throws: Any error raised while encoding authority fields.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(protocolMinimum, forKey: .protocolMinimum)
        try container.encode(protocolMaximum, forKey: .protocolMaximum)
        try container.encode(capabilities.sorted(), forKey: .capabilities)
        try container.encode(session, forKey: .session)
        try container.encode(authority.daemonInstanceID, forKey: .daemonInstanceID)
        try container.encode(authority.sessionID, forKey: .sessionID)
        try container.encode(canonicalTopologyRevision, forKey: .canonicalTopologyRevision)
        try container.encode(processID, forKey: .processID)
    }
}
