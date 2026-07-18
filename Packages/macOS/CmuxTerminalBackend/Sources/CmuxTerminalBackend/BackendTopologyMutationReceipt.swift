public import Foundation

/// Authority-fenced commit token returned by every canonical topology mutation.
public struct BackendTopologyMutationReceipt: Decodable, Equatable, Sendable {
    /// Caller idempotency key echoed by the daemon on commits and replays.
    public let requestID: UUID

    /// Daemon and logical session that committed the mutation.
    public let authority: BackendAuthority

    /// Canonical topology revision validated immediately before the mutation.
    public let baseRevision: UInt64

    /// Canonical topology revision containing the committed result.
    public let revision: UInt64

    /// Whether this response replays a previously committed idempotency key.
    public let replayed: Bool

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case baseRevision = "base_revision"
        case revision
        case replayed
    }

    /// Decodes a flat daemon mutation receipt.
    ///
    /// - Parameter decoder: Decoder containing authority and revision fields.
    /// - Throws: Any field decoding error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        authority = BackendAuthority(
            daemonInstanceID: try container.decode(DaemonInstanceID.self, forKey: .daemonInstanceID),
            sessionID: try container.decode(SessionID.self, forKey: .sessionID)
        )
        baseRevision = try container.decode(UInt64.self, forKey: .baseRevision)
        revision = try container.decode(UInt64.self, forKey: .revision)
        replayed = try container.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
    }
}
