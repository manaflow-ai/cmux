import Foundation

/// The mirror bootstrap: the user's items and who this client is.
public nonisolated struct FeedSnapshot: Sendable {
    public var revision: UInt64
    /// The user principal (`usr_…`).
    public var user: String
    /// This client's device name, stamped on the overlay of an answer.
    public var device: String
    public var items: [FeedItem]

    public init(revision: UInt64, user: String, device: String, items: [FeedItem]) {
        self.revision = revision
        self.user = user
        self.device = device
        self.items = items
    }
}

/// One committed op: every item it changed, in one event (feed.md
/// section 6). `tx` is the idempotency key of the request that caused it
/// (nil for system ops and other principals' requests).
public nonisolated struct FeedEvent: Sendable {
    public enum Change: Sendable {
        case items([FeedItem])
        /// Pruned or moved out of this stream.
        case remove([String])
    }

    public var revision: UInt64
    public var tx: String?
    public var change: Change

    public init(revision: UInt64, tx: String? = nil, change: Change) {
        self.revision = revision
        self.tx = tx
        self.change = change
    }
}
