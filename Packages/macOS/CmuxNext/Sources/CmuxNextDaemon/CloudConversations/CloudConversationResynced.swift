import Foundation

/// `cloud-conversation-resynced`: the owner's current head and tail, after
/// the first subscribe, a snapshot resume or a detected gap.

/// `cloud-conversation-resynced`: the owner's current head and tail, after
/// the first subscribe, a snapshot resume or a detected gap.
public struct CloudConversationResynced: Decodable, Sendable, Hashable {
    public var conversation: String
    public var rev: UInt64
    public var seq: UInt64
    public var summary: ConversationSummary
    public var messages: [ConversationMessage]
    /// The cloud account (the `sub` of the lease the daemon used) this
    /// event came through. Absent only for a lease without a readable
    /// `sub`; the app refuses such an event.
    public var account: String?

    public init(conversation: String, rev: UInt64, seq: UInt64, summary: ConversationSummary, messages: [ConversationMessage],
                account: String? = nil) {
        self.conversation = conversation
        self.rev = rev
        self.seq = seq
        self.summary = summary
        self.messages = messages
        self.account = account
    }
}
