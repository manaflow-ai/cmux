import Foundation

/// Durable per-machine Cloud notification delivery and read state.
public struct CloudNotificationSyncState: Codable, Equatable, Sendable {
    public typealias PendingAck = CloudNotificationSyncPendingAck

    static let deliveredLimit = 512
    static let notificationAssociationLimit = 64

    public var delivered: [String] = []
    public var pendingAcks: [PendingAck] = []
    /// Notification ids this client has acknowledged. This durable overlay
    /// keeps stale snapshots from restoring an unread projection after the
    /// feed has accepted the read, while remaining bounded like the daemon's
    /// retained notification ledger.
    public var read: [String] = []
    /// Terminal ids the person explicitly marked unread in the Cloud tree.
    /// This local overlay survives reconnects and older daemons that only
    /// expose read acknowledgements.
    public var manuallyUnreadTerminalIDs: [String] = []
    /// Durable terminal-to-notification identity. The Cloud tree can be
    /// operated while a machine is offline, so read-state actions need the
    /// daemon row ids even when no live sync has the current rows in memory.
    public var notificationIDsByTerminalID: [String: [String]] = [:]

    public init(
        delivered: [String] = [],
        pendingAcks: [PendingAck] = [],
        read: [String] = [],
        manuallyUnreadTerminalIDs: [String] = [],
        notificationIDsByTerminalID: [String: [String]] = [:]
    ) {
        self.delivered = delivered
        self.pendingAcks = pendingAcks
        self.read = read
        self.manuallyUnreadTerminalIDs = manuallyUnreadTerminalIDs
        self.notificationIDsByTerminalID = notificationIDsByTerminalID
    }

    private enum CodingKeys: String, CodingKey {
        case delivered
        case pendingAcks
        case read
        case manuallyUnreadTerminalIDs
        case notificationIDsByTerminalID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delivered = try container.decodeIfPresent([String].self, forKey: .delivered) ?? []
        pendingAcks = try container.decodeIfPresent([PendingAck].self, forKey: .pendingAcks) ?? []
        // `read` was added after the initial persisted schema. Missing data is
        // the old state, not a corrupt state that should discard delivery data.
        read = try container.decodeIfPresent([String].self, forKey: .read) ?? []
        manuallyUnreadTerminalIDs = try container.decodeIfPresent([String].self, forKey: .manuallyUnreadTerminalIDs) ?? []
        notificationIDsByTerminalID = try container.decodeIfPresent([String: [String]].self, forKey: .notificationIDsByTerminalID) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(delivered, forKey: .delivered)
        try container.encode(pendingAcks, forKey: .pendingAcks)
        try container.encode(read, forKey: .read)
        try container.encode(manuallyUnreadTerminalIDs, forKey: .manuallyUnreadTerminalIDs)
        try container.encode(notificationIDsByTerminalID, forKey: .notificationIDsByTerminalID)
    }

    public var pendingIDs: Set<String> {
        Set(pendingAcks.flatMap(\.ids))
    }

    public var readIDs: Set<String> {
        Set(read)
    }
}
