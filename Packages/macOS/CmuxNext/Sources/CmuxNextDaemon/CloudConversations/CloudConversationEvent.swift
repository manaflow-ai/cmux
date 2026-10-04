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

    public init(conversation: String, rev: UInt64, seq: UInt64, transaction: String? = nil, change: ConversationChange) {
        self.conversation = conversation
        self.rev = rev
        self.seq = seq
        self.transaction = transaction
        self.change = change
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

    public init(conversation: String, rev: UInt64, seq: UInt64, summary: ConversationSummary, messages: [ConversationMessage]) {
        self.conversation = conversation
        self.rev = rev
        self.seq = seq
        self.summary = summary
        self.messages = messages
    }
}

/// `cloud-inbox-changed`: the inbox entries one owner commit wrote.
public struct CloudInboxChanged: Decodable, Sendable, Hashable {
    public var seq: UInt64
    public var transaction: String?
    public var entries: [CloudInboxEntry]

    public init(seq: UInt64, transaction: String? = nil, entries: [CloudInboxEntry]) {
        self.seq = seq
        self.transaction = transaction
        self.entries = entries
    }
}

/// `cloud-subscription-state` of the inbox or one conversation socket.
public struct CloudSubscriptionState: Decodable, Sendable, Hashable {
    /// `inbox` or `conversation`.
    public var scope: String
    public var conversation: String?
    /// `connecting`, `live`, `disconnected` or `closed`.
    public var state: String
    /// `signed_out`, `unauthenticated`, `unavailable` (disconnected) or `forbidden` (closed).
    public var reason: String?

    public init(scope: String, conversation: String? = nil, state: String, reason: String? = nil) {
        self.scope = scope
        self.conversation = conversation
        self.state = state
        self.reason = reason
    }

    public var isLive: Bool { state == "live" }
}

/// `cloud-session-needed`: the daemon asks for a new lease.
public struct CloudSessionNeeded: Decodable, Sendable, Hashable {
    /// `missing`, `expiring`, `expired` or `unauthenticated`.
    public var reason: String
    public var expiresAt: UInt64?

    public init(reason: String, expiresAt: UInt64? = nil) {
        self.reason = reason
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case reason
        case expiresAt = "expires_at"
    }
}

/// The `cloud-conversations-v1` events (home-cloud-proxy.md section 5).
public enum CloudConversationsEvent: Sendable, Hashable {
    case changed(CloudConversationChanged)
    case resynced(CloudConversationResynced)
    case inboxChanged(CloudInboxChanged)
    /// List the inbox again.
    case inboxReset(seq: UInt64)
    case subscriptionState(CloudSubscriptionState)
    case sessionNeeded(CloudSessionNeeded)

    public static let eventNames: Set<String> = [
        "cloud-conversation-changed", "cloud-conversation-resynced", "cloud-inbox-changed", "cloud-inbox-reset",
        "cloud-subscription-state", "cloud-session-needed",
    ]

    private struct InboxReset: Decodable { var seq: UInt64? }

    /// Decodes one `cloud-*` event line; throws on a malformed payload.
    static func decode(name: String, line: Data, decoder: JSONDecoder) throws -> CloudConversationsEvent? {
        switch name {
        case "cloud-conversation-changed": .changed(try decoder.decode(CloudConversationChanged.self, from: line))
        case "cloud-conversation-resynced": .resynced(try decoder.decode(CloudConversationResynced.self, from: line))
        case "cloud-inbox-changed": .inboxChanged(try decoder.decode(CloudInboxChanged.self, from: line))
        case "cloud-inbox-reset": .inboxReset(seq: try decoder.decode(InboxReset.self, from: line).seq ?? 0)
        case "cloud-subscription-state": .subscriptionState(try decoder.decode(CloudSubscriptionState.self, from: line))
        case "cloud-session-needed": .sessionNeeded(try decoder.decode(CloudSessionNeeded.self, from: line))
        default: nil
        }
    }
}
