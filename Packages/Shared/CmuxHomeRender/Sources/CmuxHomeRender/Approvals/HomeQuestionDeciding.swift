import Foundation

/// One answer to a pending question from a trusted local Chief, as the conversation owner will
/// record it: the stored question part and the `question.answer` op's `answer` (selections only).
public struct HomeQuestionRequest: Sendable, Equatable {
    public let chief: String
    public let conversation: String
    public let message: String
    public let partIndex: Int
    /// The answer's JSON (`{"selections": {...}}`).
    public let answerJSON: Data
    public init(chief: String, conversation: String, message: String, partIndex: Int, answerJSON: Data) {
        (self.chief, self.conversation, self.message, self.partIndex, self.answerJSON) = (chief, conversation, message, partIndex, answerJSON)
    }
}

public enum HomeQuestionDecision: Sendable, Equatable {
    /// The person's signed decision (canonical JSON), for the `question.answer` op's `decision`.
    case signed(String)
    case expired, refused
}

/// Only the native app signs the person's decision for a question answer. The owner delivers
/// the answer with it, and acpmux checks and spends it. Without a decision the owner refuses
/// the answer.
public protocol HomeQuestionDeciding: AnyObject, Sendable {
    @MainActor
    func decide(_ request: HomeQuestionRequest, through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeQuestionDecision
}
