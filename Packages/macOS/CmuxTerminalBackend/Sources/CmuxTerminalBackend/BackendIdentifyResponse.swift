/// Negotiated protocol metadata returned by the backend `identify` command.
///
/// Exact build revisions are diagnostic only. Callers should negotiate the
/// protocol range and required capabilities instead of matching ``version``.
public struct BackendIdentifyResponse: Codable, Equatable, Sendable {
    /// The application identifier reported by the backend.
    public let app: String

    /// The diagnostic backend build version.
    public let version: String

    /// The backend's preferred protocol version.
    public let protocolVersion: UInt32

    /// The oldest protocol version supported by the backend.
    public let protocolMinimum: UInt32

    /// The newest protocol version supported by the backend.
    public let protocolMaximum: UInt32

    /// The protocol capabilities advertised by the backend.
    public let capabilities: Set<String>

    /// The backend session name reached by this connection.
    public let session: String

    /// The daemon-lifetime and persisted-session authority fence.
    public let authority: BackendAuthority

    /// The current canonical-topology revision.
    public let topologyRevision: UInt64

    /// The structural topology revision used by protocol-v8 snapshot resume.
    ///
    /// Older protocol-v8 daemons omit this additive field and use
    /// ``topologyRevision`` for the same structural counter.
    public let canonicalTopologyRevision: UInt64

    /// The operating-system process identifier of the backend daemon.
    public let processID: UInt32

    enum CodingKeys: String, CodingKey {
        case app
        case version
        case protocolVersion = "protocol"
        case protocolMinimum = "protocol_min"
        case protocolMaximum = "protocol_max"
        case capabilities
        case session
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case topologyRevision = "topology_revision"
        case canonicalTopologyRevision = "canonical_topology_revision"
        case processID = "pid"
    }

    /// Decodes an identify response from the backend wire format.
    ///
    /// - Parameter decoder: The decoder containing the identify payload.
    /// - Throws: Any error raised while decoding required protocol metadata.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decode(String.self, forKey: .app)
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
        topologyRevision = try container.decode(UInt64.self, forKey: .topologyRevision)
        canonicalTopologyRevision = try container.decodeIfPresent(
            UInt64.self,
            forKey: .canonicalTopologyRevision
        ) ?? topologyRevision
        processID = try container.decode(UInt32.self, forKey: .processID)
    }

    /// Encodes an identify response using the backend wire keys.
    ///
    /// - Parameter encoder: The encoder that receives the identify payload.
    /// - Throws: Any error raised while encoding protocol metadata.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app, forKey: .app)
        try container.encode(version, forKey: .version)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(protocolMinimum, forKey: .protocolMinimum)
        try container.encode(protocolMaximum, forKey: .protocolMaximum)
        try container.encode(capabilities.sorted(), forKey: .capabilities)
        try container.encode(session, forKey: .session)
        try container.encode(authority.daemonInstanceID, forKey: .daemonInstanceID)
        try container.encode(authority.sessionID, forKey: .sessionID)
        try container.encode(topologyRevision, forKey: .topologyRevision)
        try container.encode(canonicalTopologyRevision, forKey: .canonicalTopologyRevision)
        try container.encode(processID, forKey: .processID)
    }
}
