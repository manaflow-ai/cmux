import Foundation

/// A connector feature that the hub may expose to UI, socket, or CLI callers.
public enum InboxConnectorCapability: String, Codable, CaseIterable, Sendable, Hashable {
    /// The connector can deliver new items without a full manual refresh.
    case liveEvents
    /// The connector can fetch historical messages from the source service.
    case backfill
    /// The connector can mark source messages or threads read.
    case markRead
    /// The connector can send a user-approved reply.
    case sendReply
    /// The connector can open the source app or web thread.
    case deepLink
}
