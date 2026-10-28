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

    private enum CodingKeys: String, CodingKey {
        case id, author, turn, status, answers
        case threadRoot = "thread_root"
        case startedAt = "started_at"
    }
}
