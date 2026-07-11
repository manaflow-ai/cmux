import Foundation

/// Carries a question posed by the agent and optional answer state.
public struct QuestionPayload: Codable, Hashable, Sendable {
    /// The question prompt.
    public let prompt: String
    /// The available choices, if the runtime exposed them.
    public let options: [String]
    /// The answered choice index, if known.
    public let answeredChoice: Int?

    private enum CodingKeys: String, CodingKey {
        case prompt
        case options
        case answeredChoice = "answered_choice"
    }

    /// Creates a question payload.
    /// - Parameters:
    ///   - prompt: The question prompt.
    ///   - options: The available choices, if the runtime exposed them.
    ///   - answeredChoice: The answered choice index, if known.
    public init(prompt: String, options: [String], answeredChoice: Int? = nil) {
        self.prompt = prompt
        self.options = options
        self.answeredChoice = answeredChoice
    }
}
