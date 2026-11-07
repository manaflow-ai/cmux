import Foundation

/// The owner's persisted run summaries, newest first or selected by reply keys.
public struct ConversationRunsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {
        public var runs: [ConversationRunSummary]
        public var hasMore: Bool?
        private enum CodingKeys: String, CodingKey { case runs, hasMore = "has_more" }
    }
    public static let command = "conversation-runs"
    public static let requiredCapability: String? = DaemonCapability.conversationRuns.rawValue
    public var conversation: String
    public var turns: [String]?
    public var answers: [String]?
    public var beforeStartedAt: UInt64?
    public var limit = 200

    private enum CodingKeys: String, CodingKey {
        case conversation, turns, answers, limit
        case beforeStartedAt = "before_started_at"
    }

    public init(conversation: String, turns: [String]? = nil, answers: [String]? = nil, beforeStartedAt: UInt64? = nil) {
        self.conversation = conversation
        self.turns = turns
        self.answers = answers
        self.beforeStartedAt = beforeStartedAt
    }
}

extension ConversationClient {
    /// Summary pages stop at the visible transcript's oldest message. Reply-key lookups
    /// additionally find runs that began before their already-loaded replies. Answer
    /// lookups recover silent reports without a posted reply, including running-agent
    /// follow-ups whose original run began before the visible question. The batches and
    /// the cursor are the SDK's rules (``ConversationRules``); this reads the pages.
    public func runs(_ conversation: String, oldestStartedAt: Double, turns: [String], answers: [String] = []) async throws -> [ConversationRunSummary] {
        guard await connection.identity?.supports(DaemonCapability.conversationRuns.rawValue) == true else { return [] }
        let rules = ConversationRules()
        let answersServed = await connection.identity?.supports(DaemonCapability.conversationRunAnswers.rawValue) == true
        var result: [ConversationRunSummary] = []
        for batch in try rules.runsKeyBatches(turns: turns, answers: answers, answersServed: answersServed) {
            try Task.checkCancellation()
            result += try await connection.request(ConversationRunsRequest(conversation: conversation, turns: batch.turns,
                                                                           answers: batch.answers)).runs
        }
        var before: UInt64?
        // wakeup-allow: every iteration awaits an owner request; EOF, a nonadvancing cursor, or cancellation ends pagination.
        while !Task.isCancelled {
            let page = try await connection.request(ConversationRunsRequest(conversation: conversation, beforeStartedAt: before))
            result += page.runs
            guard let next = try rules.runsNext(cloud: false, runs: page.runs, hasMore: page.hasMore == true, before: before,
                                                oldestStartedAt: oldestStartedAt).before else { break }
            before = next
        }
        return result
    }
}
