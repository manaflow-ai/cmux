import Foundation

/// Durable per-machine Cloud notification delivery and read state.
public struct CloudNotificationSyncState: Codable, Equatable, Sendable {
    public typealias PendingAck = CloudNotificationSyncPendingAck

    static let deliveredLimit = 512

    public var delivered: [String] = []
    public var pendingAcks: [PendingAck] = []
    /// Notification ids this client has acknowledged. This durable overlay
    /// keeps stale snapshots from restoring an unread projection after the
    /// feed has accepted the read, while remaining bounded like the daemon's
    /// retained notification ledger.
    public var read: [String] = []

    public init(
        delivered: [String] = [],
        pendingAcks: [PendingAck] = [],
        read: [String] = []
    ) {
        self.delivered = delivered
        self.pendingAcks = pendingAcks
        self.read = read
    }

    private enum CodingKeys: String, CodingKey {
        case delivered
        case pendingAcks
        case read
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delivered = try container.decodeIfPresent([String].self, forKey: .delivered) ?? []
        pendingAcks = try container.decodeIfPresent([PendingAck].self, forKey: .pendingAcks) ?? []
        // `read` was added after the initial persisted schema. Missing data is
        // the old state, not a corrupt state that should discard delivery data.
        read = try container.decodeIfPresent([String].self, forKey: .read) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(delivered, forKey: .delivered)
        try container.encode(pendingAcks, forKey: .pendingAcks)
        try container.encode(read, forKey: .read)
    }

    public var pendingIDs: Set<String> {
        Set(pendingAcks.flatMap(\.ids))
    }

    public var readIDs: Set<String> {
        Set(read)
    }
}
