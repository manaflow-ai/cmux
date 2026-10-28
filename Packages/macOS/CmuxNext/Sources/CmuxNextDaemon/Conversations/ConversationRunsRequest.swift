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
    public var beforeStartedAt: UInt64?
    public var limit = 200

    private enum CodingKeys: String, CodingKey {
        case conversation, turns, limit
        case beforeStartedAt = "before_started_at"
    }

    public init(conversation: String, turns: [String]? = nil, beforeStartedAt: UInt64? = nil) {
        self.conversation = conversation
        self.turns = turns
        self.beforeStartedAt = beforeStartedAt
    }
}

extension ConversationClient {
    public func runs(_ conversation: String, turns: [String]? = nil) async throws -> [ConversationRunSummary] {
        guard await connection.identity?.supports(DaemonCapability.conversationRuns.rawValue) == true else { return [] }
        if let turns, !turns.isEmpty {
            return try await connection.request(ConversationRunsRequest(conversation: conversation, turns: turns)).runs
        }
        var result: [ConversationRunSummary] = []
        var before: UInt64?
        for _ in 0..<8 {
            let page = try await connection.request(ConversationRunsRequest(conversation: conversation, beforeStartedAt: before))
            result += page.runs
            guard page.hasMore == true, let oldest = page.runs.compactMap({ $0.startedAt }).min(), oldest > 0 else { break }
            before = UInt64(oldest)
        }
        return result
    }
}
