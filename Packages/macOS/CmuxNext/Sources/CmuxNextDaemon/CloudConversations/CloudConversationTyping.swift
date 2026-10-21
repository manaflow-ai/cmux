import Foundation

/// `cloud-conversation-typing`: someone in a subscribed Cloud conversation started or stopped
/// typing (the owner's `conversation-typing` broadcast). Ephemeral: never stored or replayed.
public struct CloudConversationTyping: Decodable, Sendable, Hashable {
    public var conversation: String
    public var participant: String
    public var on: Bool
    /// The cloud account (the lease's `sub`) this event came through.
    public var account: String?

    public init(conversation: String, participant: String, on: Bool, account: String? = nil) {
        self.conversation = conversation
        self.participant = participant
        self.on = on
        self.account = account
    }
}
