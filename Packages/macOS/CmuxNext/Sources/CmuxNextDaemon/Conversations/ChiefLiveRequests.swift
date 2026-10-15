import Foundation

/// `conversation-live {conversation}` (`chief-live-v1`): the local owner's
/// `run.live` snapshot of a conversation, the text so far and the activity of
/// every running run. Home asks when it opens a conversation and after a gap.
public struct ConversationLiveRequest: DaemonRequest {
    public typealias Response = ChiefLiveFrame
    public static let command = "conversation-live"
    public static let requiredCapability: String? = DaemonCapabilities.shared.chiefLive
    public var conversation: String

    public init(conversation: String) {
        self.conversation = conversation
    }
}

/// `cloud-conversation-live {conversation}` (`cloud-chief-live-v1`): asks a
/// subscribed Cloud conversation's owner for its `run.live` snapshot; the
/// answer comes later as a `cloud-conversation-live` event.
public struct CloudConversationLiveRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "cloud-conversation-live"
    public static let requiredCapability: String? = DaemonCapabilities.shared.cloudChiefLive
    public var conversation: String

    public init(conversation: String) {
        self.conversation = conversation
    }
}

extension ConversationClient {
    /// The `run.live` snapshot of `conversation`; nil from a daemon without `chief-live-v1`.
    public func live(_ conversation: String) async throws -> ChiefLiveFrame? {
        guard await connection.identity?.supports(DaemonCapabilities.shared.chiefLive) == true else { return nil }
        return try await connection.request(ConversationLiveRequest(conversation: conversation))
    }
}
