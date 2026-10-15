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

/// The steps of one run (`conversation-run`, `cloud-conversation-run`): Home reads the
/// talk steps' text to show reply segments a live buffer already freed (a mid-run join).
public struct ConversationRunRows: Decodable, Sendable, Hashable {
    public struct Step: Decodable, Sendable, Hashable {
        public var id: String
        public var kind: String
        public var text: String?
    }

    public var steps: [Step]
}

/// `conversation-run {conversation, run}` (`conversation-runs-v1`): every step of a local run.
public struct ConversationRunRequest: DaemonRequest {
    public typealias Response = ConversationRunRows
    public static let command = "conversation-run"
    public static let requiredCapability: String? = DaemonCapabilities.shared.conversationRuns
    public var conversation: String
    public var run: String

    public init(conversation: String, run: String) {
        self.conversation = conversation
        self.run = run
    }
}

/// `cloud-conversation-run {conversation, agent, run}` (`cloud-conversation-runs-v1`): a Cloud Chief's run.
public struct CloudConversationRunRequest: DaemonRequest {
    public typealias Response = ConversationRunRows
    public static let command = "cloud-conversation-run"
    public static let requiredCapability: String? = DaemonCapabilities.shared.cloudConversationRuns
    public var conversation: String
    public var agent: String
    public var run: String

    public init(conversation: String, agent: String, run: String) {
        self.conversation = conversation
        self.agent = agent
        self.run = run
    }
}

extension ConversationClient {
    /// The steps of `run`; nil from a daemon without `conversation-runs-v1`.
    public func runRows(_ conversation: String, run: String) async throws -> ConversationRunRows? {
        guard await connection.identity?.supports(DaemonCapabilities.shared.conversationRuns) == true else { return nil }
        return try await connection.request(ConversationRunRequest(conversation: conversation, run: run))
    }
}
