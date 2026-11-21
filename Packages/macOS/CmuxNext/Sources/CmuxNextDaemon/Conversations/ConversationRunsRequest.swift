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
    /// follow-ups whose original run began before the visible question.
    public func runs(_ conversation: String, oldestStartedAt: Double, turns: [String], answers: [String] = []) async throws -> [ConversationRunSummary] {
        guard await connection.identity?.supports(DaemonCapability.conversationRuns.rawValue) == true else { return [] }
        var result: [ConversationRunSummary] = []
        for offset in stride(from: 0, to: turns.count, by: 200) {
            try Task.checkCancellation()
            let keys = Array(turns.dropFirst(offset).prefix(200))
            result += try await connection.request(ConversationRunsRequest(conversation: conversation, turns: keys)).runs
        }
        if await connection.identity?.supports(DaemonCapability.conversationRunAnswers.rawValue) == true {
            for offset in stride(from: 0, to: answers.count, by: 200) {
                try Task.checkCancellation()
                let ids = Array(answers.dropFirst(offset).prefix(200))
                result += try await connection.request(ConversationRunsRequest(conversation: conversation, answers: ids)).runs
            }
        }
        var before: UInt64?
        // wakeup-allow: every iteration awaits an owner request; EOF, a nonadvancing cursor, or cancellation ends pagination.
        while !Task.isCancelled {
            let page = try await connection.request(ConversationRunsRequest(conversation: conversation, beforeStartedAt: before))
            result += page.runs
            guard page.hasMore == true, let oldest = page.runs.compactMap(\.startedAt).min(),
                  oldest.isFinite, oldest > max(0, oldestStartedAt), oldest < Double(UInt64.max) else { break }
            guard let next = UInt64(exactly: oldest) else { break }
            guard before.map({ next < $0 }) ?? true else { break }
            before = next
        }
        return result
    }
}
