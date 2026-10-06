import Foundation

/// The `cloud-conversations-v1` events (home-cloud-proxy.md section 5).

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
