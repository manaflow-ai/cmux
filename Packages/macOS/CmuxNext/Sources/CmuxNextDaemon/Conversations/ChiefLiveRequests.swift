import Foundation

/// `conversation-live {conversation}` (`chief-live-v1`): the local owner's
/// `run.live` snapshot of a conversation, the text so far and the activity of
/// every running run. Home asks when it opens a conversation and after a gap.
public struct ConversationLiveRequest: DaemonRequest {
    public typealias Response = ChiefLiveFrame
    public static let command = "conversation-live"
    public static let requiredCapability: String? = DaemonCapability.chiefLive.rawValue
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
    public static let requiredCapability: String? = DaemonCapability.cloudChiefLive.rawValue
    public var conversation: String

    public init(conversation: String) {
        self.conversation = conversation
    }
}

extension ConversationClient {
    /// The `run.live` snapshot of `conversation`; nil from a daemon without `chief-live-v1`.
    public func live(_ conversation: String) async throws -> ChiefLiveFrame? {
        guard await connection.identity?.supports(DaemonCapability.chiefLive.rawValue) == true else { return nil }
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
        /// The row's text was cut (32 KiB): not the step's whole text.
        public var truncated: Bool?
        /// Local: the step's write revision; Cloud: its place.
        public var rev: UInt64?
        public var seq: UInt64?
    }

    public var steps: [Step]
    public var hasMore: Bool?

    private enum CodingKeys: String, CodingKey {
        case steps
        case hasMore = "has_more"
    }
}

/// `conversation-run {conversation, run}` (`conversation-runs-v1`): every step of a local run.
public struct ConversationRunRequest: DaemonRequest {
    public typealias Response = ConversationRunRows
    public static let command = "conversation-run"
    public static let requiredCapability: String? = DaemonCapability.conversationRuns.rawValue
    public var conversation: String
    public var run: String
    public var afterRev: UInt64?

    public init(conversation: String, run: String, afterRev: UInt64? = nil) {
        self.conversation = conversation
        self.run = run
        self.afterRev = afterRev
    }
}

/// `cloud-conversation-run {conversation, agent, run}` (`cloud-conversation-runs-v1`): a Cloud Chief's run.
public struct CloudConversationRunRequest: DaemonRequest {
    public typealias Response = ConversationRunRows
    public static let command = "cloud-conversation-run"
    public static let requiredCapability: String? = DaemonCapability.cloudConversationRuns.rawValue
    public var conversation: String
    public var agent: String
    public var run: String
    public var afterSeq: UInt64?

    public init(conversation: String, agent: String, run: String, afterSeq: UInt64? = nil) {
        self.conversation = conversation
        self.agent = agent
        self.run = run
        self.afterSeq = afterSeq
    }
}

extension ConversationClient {
    /// Every step of `run` (pages read on while `has_more`, at most 8); nil from a daemon without `conversation-runs-v1`.
    public func runRows(_ conversation: String, run: String) async throws -> ConversationRunRows? {
        guard await connection.identity?.supports(DaemonCapability.conversationRuns.rawValue) == true else { return nil }
        var all = try await connection.request(ConversationRunRequest(conversation: conversation, run: run))
        var pages = 1
        while all.hasMore == true, pages < 8, let last = all.steps.compactMap(\.rev).max() {
            let next = try await connection.request(ConversationRunRequest(conversation: conversation, run: run, afterRev: last))
            all.steps += next.steps
            all.hasMore = next.hasMore
            pages += 1
        }
        return all
    }
}
