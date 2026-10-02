import Foundation

/// What a conversation tab shows (`conversation-tabs-v1`, plans/cmux-next/home.md 7):
/// one conversation of the `local` (daemon) or `cloud` conversation owner. The
/// store never reads conversation content; the app renders it from the owner.
public struct ConversationTabRef: Sendable, Hashable, Codable {
    public var conversation: String
    public var owner: String

    public init(conversation: String, owner: String) {
        self.conversation = conversation
        self.owner = owner
    }
}
