/// One committed topology transaction whose revision and replacement are atomic.
public struct TopologyDelta: Codable, Equatable, Sendable {
    /// The daemon and session that committed this transaction.
    public let authority: BackendAuthority

    /// The revision that the transaction advances from.
    public let baseRevision: UInt64

    /// The revision produced by the transaction.
    public let revision: UInt64

    /// The structural operation committed by the transaction.
    public let operation: TopologyOperation

    /// The stable entities affected by the transaction.
    public let targets: TopologyTargets

    /// The complete canonical topology at ``revision``.
    public let replacement: CanonicalTopology

    /// Creates one committed topology transaction.
    ///
    /// - Parameters:
    ///   - authority: The daemon and session that committed the transaction.
    ///   - baseRevision: The revision advanced from.
    ///   - revision: The revision produced by the transaction.
    ///   - operation: The structural operation that was committed.
    ///   - targets: The stable entities affected by the transaction.
    ///   - replacement: The complete topology at the new revision.
    public init(
        authority: BackendAuthority,
        baseRevision: UInt64,
        revision: UInt64,
        operation: TopologyOperation,
        targets: TopologyTargets,
        replacement: CanonicalTopology
    ) {
        self.authority = authority
        self.baseRevision = baseRevision
        self.revision = revision
        self.operation = operation
        self.targets = targets
        self.replacement = replacement
    }

    enum CodingKeys: String, CodingKey {
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case baseRevision = "base_revision"
        case revision
        case operation
        case targets
        case replacement
    }

    /// Decodes a topology transaction from the backend wire format.
    ///
    /// - Parameter decoder: The decoder containing the transaction payload.
    /// - Throws: Any error raised while decoding required fields or topology state.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authority = BackendAuthority(
            daemonInstanceID: try container.decode(DaemonInstanceID.self, forKey: .daemonInstanceID),
            sessionID: try container.decode(SessionID.self, forKey: .sessionID)
        )
        baseRevision = try container.decode(UInt64.self, forKey: .baseRevision)
        revision = try container.decode(UInt64.self, forKey: .revision)
        operation = try container.decode(TopologyOperation.self, forKey: .operation)
        targets = try container.decode(TopologyTargets.self, forKey: .targets)
        replacement = try container.decode(CanonicalTopology.self, forKey: .replacement)
    }

    /// Encodes a topology transaction using the backend wire keys.
    ///
    /// - Parameter encoder: The encoder that receives the transaction payload.
    /// - Throws: Any error raised while encoding the transaction.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authority.daemonInstanceID, forKey: .daemonInstanceID)
        try container.encode(authority.sessionID, forKey: .sessionID)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode(revision, forKey: .revision)
        try container.encode(operation, forKey: .operation)
        try container.encode(targets, forKey: .targets)
        try container.encode(replacement, forKey: .replacement)
    }
}
