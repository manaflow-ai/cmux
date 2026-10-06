import Foundation

/// `cloud-conversation-changed`: one committed op on a cloud conversation,
/// in `seq` order, exactly once. `rev` is the head's revision after it.
public struct CloudConversationChanged: Decodable, Sendable, Hashable {
    public var conversation: String
    public var rev: UInt64
    public var seq: UInt64
    /// The cloud transaction (not a daemon `ClientTransactionID`).
    public var transaction: String?
    public var change: ConversationChange
    /// The cloud account (the `sub` of the lease the daemon used) this
    /// event came through. Absent only for a lease without a readable
    /// `sub`; the app refuses such an event.
    public var account: String?

    public init(conversation: String, rev: UInt64, seq: UInt64, transaction: String? = nil, change: ConversationChange,
                account: String? = nil) {
        self.conversation = conversation
        self.rev = rev
        self.seq = seq
        self.transaction = transaction
        self.change = change
        self.account = account
    }
}
