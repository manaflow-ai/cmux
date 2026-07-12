import Foundation

/// Carries a question posed by the agent and optional answer state.
public struct QuestionPayload: Codable, Hashable, Sendable {
    /// Runtime-stable identifier for this question, when exposed.
    public let questionID: String?
    /// Short question header, when exposed.
    public let header: String?
    /// The question prompt.
    public let prompt: String
    /// The available choices, if the runtime exposed them.
    public let options: [String]
    /// The answered choice index, if known.
    public let answeredChoice: Int?

    private enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case header
        case prompt
        case options
        case answeredChoice = "answered_choice"
    }

    /// Creates a question payload.
    /// - Parameters:
    ///   - prompt: The question prompt.
    ///   - options: The available choices, if the runtime exposed them.
    ///   - answeredChoice: The answered choice index, if known.
    public init(
        questionID: String? = nil,
        header: String? = nil,
        prompt: String,
        options: [String],
        answeredChoice: Int? = nil
    ) {
        self.questionID = questionID
        self.header = header
        self.prompt = prompt
        self.options = options
        self.answeredChoice = answeredChoice
    }
}
