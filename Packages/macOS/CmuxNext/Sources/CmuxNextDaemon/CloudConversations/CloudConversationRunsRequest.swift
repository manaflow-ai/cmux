import Foundation

/// Persisted runs of one hosted Chief; the brain lists newest first.
public struct CloudConversationRunsRequest: DaemonRequest {
    public typealias Response = ConversationRunsRequest.Response
    public static let command = "cloud-conversation-runs"
    public static let requiredCapability: String? = DaemonCapability.cloudConversationRuns.rawValue
    public var conversation: String
    public var agent: String
    public var beforeStartedAt: UInt64?
    public var limit = 100

    private enum CodingKeys: String, CodingKey {
        case conversation, agent, limit
        case beforeStartedAt = "before_started_at"
    }

    public init(conversation: String, agent: String, beforeStartedAt: UInt64? = nil) {
        self.conversation = conversation
        self.agent = agent
        self.beforeStartedAt = beforeStartedAt
    }
}
