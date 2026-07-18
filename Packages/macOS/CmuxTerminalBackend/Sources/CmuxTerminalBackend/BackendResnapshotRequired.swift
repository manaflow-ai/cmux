/// An authoritative instruction to discard local topology and request a new snapshot.
public struct BackendResnapshotRequired: Codable, Equatable, Sendable {
    /// The daemon and session issuing the instruction.
    public let authority: BackendAuthority

    /// The daemon's current revision, or `nil` when no current revision applies.
    public let currentRevision: UInt64?

    /// The reason incremental replay cannot continue.
    public let reason: TopologyResnapshotReason

    enum CodingKeys: String, CodingKey {
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case currentRevision = "current_revision"
        case reason
    }

    /// Creates a resnapshot instruction.
    ///
    /// - Parameters:
    ///   - authority: The daemon and session issuing the instruction.
    ///   - currentRevision: The daemon's current revision, when available.
    ///   - reason: The reason incremental replay cannot continue.
    public init(
        authority: BackendAuthority,
        currentRevision: UInt64?,
        reason: TopologyResnapshotReason
    ) {
        self.authority = authority
        self.currentRevision = currentRevision
        self.reason = reason
    }

    /// Decodes a resnapshot instruction from the backend wire format.
    ///
    /// - Parameter decoder: The decoder containing the instruction payload.
    /// - Throws: Any error raised while decoding required fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authority = BackendAuthority(
            daemonInstanceID: try container.decode(DaemonInstanceID.self, forKey: .daemonInstanceID),
            sessionID: try container.decode(SessionID.self, forKey: .sessionID)
        )
        currentRevision = try container.decodeIfPresent(UInt64.self, forKey: .currentRevision)
        reason = try container.decode(TopologyResnapshotReason.self, forKey: .reason)
    }

    /// Encodes a resnapshot instruction using the backend wire keys.
    ///
    /// - Parameter encoder: The encoder that receives the instruction payload.
    /// - Throws: Any error raised while encoding the instruction.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authority.daemonInstanceID, forKey: .daemonInstanceID)
        try container.encode(authority.sessionID, forKey: .sessionID)
        try container.encodeIfPresent(currentRevision, forKey: .currentRevision)
        try container.encode(reason, forKey: .reason)
    }
}
