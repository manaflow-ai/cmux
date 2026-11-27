import Foundation

/// A persisted run's identity and placement in a conversation, including finished runs.
public struct ConversationRunSummary: Decodable, Sendable, Hashable {
    public var id: String
    public var author: String
    public var turn: String?
    public var status: String
    public var answers: [String]?
    public var threadRoot: String?
    public var startedAt: Double?
    public var rev: UInt64?
    public var lastStepSeq: UInt64?

    private enum CodingKeys: String, CodingKey {
        case id, author, turn, status, answers, rev
        case threadRoot = "thread_root"
        case startedAt = "started_at"
        case lastStepSeq = "last_step_seq"
    }
}
