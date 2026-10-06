import Foundation

/// `cloud-inbox-changed`: the inbox entries one owner commit wrote.

/// `cloud-inbox-changed`: the inbox entries one owner commit wrote.
public struct CloudInboxChanged: Decodable, Sendable, Hashable {
    public var seq: UInt64
    public var transaction: String?
    public var entries: [CloudInboxEntry]
    /// The cloud account (the `sub` of the lease the daemon used) this
    /// event came through. Absent only for a lease without a readable
    /// `sub`; the app refuses such an event.
    public var account: String?

    public init(seq: UInt64, transaction: String? = nil, entries: [CloudInboxEntry], account: String? = nil) {
        self.seq = seq
        self.transaction = transaction
        self.entries = entries
        self.account = account
    }
}
