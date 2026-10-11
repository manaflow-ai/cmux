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

/// The `cloud-conversations-v1` events (home-cloud-proxy.md section 5).
public enum CloudConversationsEvent: Sendable, Hashable {
    case changed(CloudConversationChanged)
    case resynced(CloudConversationResynced)
    case inboxChanged(CloudInboxChanged)
    /// List the inbox again. `account` is the lease's `sub`, when the daemon names it.
    case inboxReset(seq: UInt64, account: String? = nil)
    case subscriptionState(CloudSubscriptionState)
    case sessionNeeded(CloudSessionNeeded)

    public static let eventNames: Set<String> = [
        "cloud-conversation-changed", "cloud-conversation-resynced", "cloud-inbox-changed", "cloud-inbox-reset",
        "cloud-subscription-state", "cloud-session-needed",
    ]

    private struct InboxReset: Decodable {
        var seq: UInt64?
        var account: String?
    }

    private static func reset(from reset: InboxReset) -> CloudConversationsEvent {
        .inboxReset(seq: reset.seq ?? 0, account: reset.account)
    }

    /// Decodes one `cloud-*` event line; throws on a malformed payload.
    static func decode(name: String, line: Data, decoder: JSONDecoder) throws -> CloudConversationsEvent? {
        switch name {
        case "cloud-conversation-changed": .changed(try decoder.decode(CloudConversationChanged.self, from: line))
        case "cloud-conversation-resynced": .resynced(try decoder.decode(CloudConversationResynced.self, from: line))
        case "cloud-inbox-changed": .inboxChanged(try decoder.decode(CloudInboxChanged.self, from: line))
        case "cloud-inbox-reset": try reset(from: decoder.decode(InboxReset.self, from: line))
        case "cloud-subscription-state": .subscriptionState(try decoder.decode(CloudSubscriptionState.self, from: line))
        case "cloud-session-needed": .sessionNeeded(try decoder.decode(CloudSessionNeeded.self, from: line))
        default: nil
        }
    }
}
