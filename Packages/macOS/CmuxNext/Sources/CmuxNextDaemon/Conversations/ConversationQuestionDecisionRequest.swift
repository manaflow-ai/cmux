public import Foundation

/// `conversation-question-decision` (`conversation-question-decision-v1`): what Home's native card
/// has the person sign before it answers a Chief question. The daemon checks the stored question is
/// the live acpmux prompt and returns the unsigned decision: `session`, `permission`, `option_id`,
/// `instance`, `decision_nonce`, the exact `answers` it will send, the stored `question`, and the
/// live `request` with its `digest`. The reply grants nothing; the app checks it against its own
/// person-proven read before it signs, and acpmux alone verifies and spends the proof.
public struct ConversationQuestionDecisionRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "conversation-question-decision"
    public static let requiredCapability: String? = DaemonCapability.conversationQuestionDecision.rawValue
    public var conversation: String
    public var messageID: String
    public var partIndex: Int
    /// The `question.answer` op's `answer` (selections only).
    public var answer: JSONValue
    /// `true`: only the stored tool-approval card, `{question}`, for its native record after the
    /// app answered acpmux itself. The daemon reads no prompt and builds no decision.
    public var nativeRecord: Bool
    /// The question part exactly as the person was shown it. The daemon refuses `question.stale`
    /// unless it equals the stored question.
    public var question: JSONValue?

    public init(conversation: String, messageID: String, partIndex: Int, answer: JSONValue, nativeRecord: Bool = false,
                question: JSONValue? = nil) {
        (self.conversation, self.messageID, self.partIndex, self.answer, self.nativeRecord) = (conversation, messageID, partIndex, answer, nativeRecord)
        self.question = question
    }

    enum CodingKeys: String, CodingKey {
        case conversation, answer, question
        case messageID = "message_id"
        case partIndex = "part_index"
        case nativeRecord = "native_record"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(partIndex, forKey: .partIndex)
        try container.encode(answer, forKey: .answer)
        if nativeRecord { try container.encode(true, forKey: .nativeRecord) }
        try container.encodeIfPresent(question, forKey: .question)
    }
}
