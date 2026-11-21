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

    public init(conversation: String, messageID: String, partIndex: Int, answer: JSONValue) {
        (self.conversation, self.messageID, self.partIndex, self.answer) = (conversation, messageID, partIndex, answer)
    }

    enum CodingKeys: String, CodingKey {
        case conversation, answer
        case messageID = "message_id"
        case partIndex = "part_index"
    }
}
