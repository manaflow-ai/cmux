
/// `cloud-conversation-unsubscribe`.

/// `cloud-conversation-unsubscribe`.
public struct CloudConversationUnsubscribeRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "cloud-conversation-unsubscribe"
    public var conversation: String
    public init(conversation: String) { self.conversation = conversation }
}
