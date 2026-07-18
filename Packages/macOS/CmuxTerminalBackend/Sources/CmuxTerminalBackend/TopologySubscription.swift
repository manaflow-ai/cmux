/// Metadata confirming that a topology stream resumed from a requested revision.
public struct TopologySubscription: Decodable, Equatable, Sendable {
    /// The daemon and session serving the stream.
    public let authority: BackendAuthority

    /// The first revision requested by the client.
    public let fromRevision: UInt64

    /// The daemon's current revision when it accepted the subscription.
    public let currentRevision: UInt64

    /// The number of retained deltas replayed before live delivery.
    public let replayed: UInt64

    enum CodingKeys: String, CodingKey {
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case fromRevision = "from_revision"
        case currentRevision = "current_revision"
        case replayed
    }

    /// Decodes subscription metadata from the backend wire format.
    ///
    /// - Parameter decoder: The decoder containing the subscription payload.
    /// - Throws: Any error raised while decoding required fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authority = BackendAuthority(
            daemonInstanceID: try container.decode(DaemonInstanceID.self, forKey: .daemonInstanceID),
            sessionID: try container.decode(SessionID.self, forKey: .sessionID)
        )
        fromRevision = try container.decode(UInt64.self, forKey: .fromRevision)
        currentRevision = try container.decode(UInt64.self, forKey: .currentRevision)
        replayed = try container.decode(UInt64.self, forKey: .replayed)
    }
}
