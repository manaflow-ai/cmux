/// One linearizable canonical-topology snapshot.
public struct TopologySnapshot: Codable, Equatable, Sendable {
    /// The daemon and session that produced this snapshot.
    public let authority: BackendAuthority

    /// The canonical revision represented by ``topology``.
    public let revision: UInt64

    /// The complete canonical topology at ``revision``.
    public let topology: CanonicalTopology

    /// Creates an authoritative topology snapshot.
    ///
    /// - Parameters:
    ///   - authority: The daemon and session that produced the snapshot.
    ///   - revision: The canonical revision represented by the snapshot.
    ///   - topology: The complete canonical topology at that revision.
    public init(authority: BackendAuthority, revision: UInt64, topology: CanonicalTopology) {
        self.authority = authority
        self.revision = revision
        self.topology = topology
    }

    enum CodingKeys: String, CodingKey {
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case revision
        case topology
    }

    /// Decodes a topology snapshot from the backend wire format.
    ///
    /// - Parameter decoder: The decoder containing the snapshot payload.
    /// - Throws: Any error raised while decoding or validating the topology.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authority = BackendAuthority(
            daemonInstanceID: try container.decode(DaemonInstanceID.self, forKey: .daemonInstanceID),
            sessionID: try container.decode(SessionID.self, forKey: .sessionID)
        )
        revision = try container.decode(UInt64.self, forKey: .revision)
        topology = try container.decode(CanonicalTopology.self, forKey: .topology)
    }

    /// Encodes a topology snapshot using the backend wire keys.
    ///
    /// - Parameter encoder: The encoder that receives the snapshot payload.
    /// - Throws: Any error raised while encoding the snapshot.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authority.daemonInstanceID, forKey: .daemonInstanceID)
        try container.encode(authority.sessionID, forKey: .sessionID)
        try container.encode(revision, forKey: .revision)
        try container.encode(topology, forKey: .topology)
    }
}
