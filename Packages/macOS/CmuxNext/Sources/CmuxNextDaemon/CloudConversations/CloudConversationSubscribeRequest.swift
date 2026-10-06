import Foundation

/// `cloud-conversation-subscribe`: at most 64 per daemon (`too_many_subscriptions`).

/// `cloud-conversation-subscribe`: at most 64 per daemon (`too_many_subscriptions`).
public struct CloudConversationSubscribeRequest: DaemonRequest {
    public typealias Response = CloudSubscription
    public static let command = "cloud-conversation-subscribe"
    public static let maxSubscriptions = 64
    public var conversation: String
    public init(conversation: String) { self.conversation = conversation }
}
