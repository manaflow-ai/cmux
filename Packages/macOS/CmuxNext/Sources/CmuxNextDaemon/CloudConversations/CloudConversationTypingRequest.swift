import Foundation

/// `cloud-conversation-typing {conversation, on}` (`cloud-conversation-typing-v1`): the person is
/// typing (`on`) or stopped in a subscribed Cloud conversation. The daemon sends the owner's
/// ephemeral typing frame on the conversation's shared socket; nothing is stored. A conversation
/// no client subscribes is refused `not_subscribed`.
public struct CloudConversationTypingRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "cloud-conversation-typing"
    public static let requiredCapability: String? = DaemonCapability.cloudConversationTyping.rawValue
    public var conversation: String
    public var on: Bool

    public init(conversation: String, on: Bool) {
        self.conversation = conversation
        self.on = on
    }
}
