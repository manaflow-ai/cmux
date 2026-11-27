import Foundation

// `local-conversations-v1` reads (plans/cmux-next/home.md section 2).

/// `conversation-list`: every conversation, newest `updated_at` first.
public struct ListConversationsRequest: DaemonRequest {
    public typealias Response = ConversationList
    public static let command = "conversation-list"
    public static let requiredCapability: String? = DaemonCapability.localConversations.rawValue
    public init() {}
}
