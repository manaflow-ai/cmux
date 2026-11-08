/// A multiple-choice question the agent asked the user.
///
/// Sourced from `AskUserQuestion`-style tool invocations. Options render as
/// in-card buttons; a free-text reply through the composer is always
/// available as well.
public struct ChatQuestion: Sendable, Equatable, Codable {
    /// One selectable answer.
    public struct Option: Sendable, Equatable, Codable, Identifiable {
        /// Stable identity within the question (the option's index as text).
        public var id: String { label }

        /// The display text of the option.
        public let label: String

        /// Optional longer explanation of the option.
        public let detail: String?

        /// Creates an option.
        ///
        /// - Parameters:
        ///   - label: Display text.
        ///   - detail: Optional longer explanation.
        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }

        private enum CodingKeys: String, CodingKey {
            case label
            case detail
        }
    }

    /// The question text.
    public let prompt: String

    /// The selectable answers, in display order.
    public let options: [Option]

    /// The label of the chosen option once answered, `nil` while pending.
    public let selectedOptionLabel: String?

    /// The agent's own id for this question, when it keys answers by id rather
    /// than by prompt (Codex `request_user_input` does; Claude keys by prompt,
    /// so this is `nil` there). Lets a multi-question call resolve each card to
    /// its own answer.
    public let questionID: String?

    /// Creates a question.
    ///
    /// - Parameters:
    ///   - prompt: The question text.
    ///   - options: Selectable answers in display order.
    ///   - selectedOptionLabel: Chosen option label once answered.
    ///   - questionID: The agent's id for this question, when answers are keyed
    ///     by id (Codex). `nil` for prompt-keyed agents (Claude).
    public init(
        prompt: String,
        options: [Option],
        selectedOptionLabel: String? = nil,
        questionID: String? = nil
    ) {
        self.prompt = prompt
        self.options = options
        self.selectedOptionLabel = selectedOptionLabel
        self.questionID = questionID
    }

    private enum CodingKeys: String, CodingKey {
        case prompt
        case options
        case selectedOptionLabel = "selected_option_label"
        case questionID = "question_id"
    }
}
