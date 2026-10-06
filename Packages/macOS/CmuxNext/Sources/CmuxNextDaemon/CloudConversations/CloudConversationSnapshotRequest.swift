import Foundation

/// `cloud-conversation-snapshot`: the head and the newest `tail` (1...50) messages.

/// `cloud-conversation-snapshot`: the head and the newest `tail` (1...50) messages.
public struct CloudConversationSnapshotRequest: DaemonRequest {
    public typealias Response = CloudConversationSnapshot
    public static let command = "cloud-conversation-snapshot"
    /// The owner returns at most this many messages.
    public static let maxTail = 50
    public var conversation: String
    public var tail: Int
    public init(conversation: String, tail: Int) {
        self.conversation = conversation
        self.tail = min(max(tail, 1), Self.maxTail)
    }
}
