/// A multiple-choice question the agent asked the user.
///
/// Sourced from `AskUserQuestion`-style tool invocations. Options render as
/// in-card buttons; a free-text reply through the composer is always
/// available as well.
public struct ChatQuestion: Sendable, Equatable, Codable {
    /// One selectable answer.
    public struct Option: Sendable, Equatable, Codable, Identifiable {
        /// Stable provider identity within the question. Older payloads may
        /// omit it; those safely fall back to the display label.
        public let optionID: String?

        public var id: String { optionID ?? label }

        /// The display text of the option.
        public let label: String

        /// Optional longer explanation of the option.
        public let detail: String?

        /// Creates an option.
        ///
        /// - Parameters:
        ///   - label: Display text.
        ///   - detail: Optional longer explanation.
        public init(label: String, detail: String? = nil, id: String? = nil) {
            self.optionID = id
            self.label = label
            self.detail = detail
        }

        private enum CodingKeys: String, CodingKey {
            case optionID = "id"
            case label
            case detail
        }
    }

    /// The question text.
    public let prompt: String

    /// The selectable answers, in display order.
    public let options: [Option]

    /// Whether the provider allows more than one option for this question.
    /// Older hosts omitted this field and therefore decode as single-select.
    public let multiSelect: Bool

    /// The label of the chosen option once answered, `nil` while pending.
    public let selectedOptionLabel: String?

    /// The agent's own id for this question, when it keys answers by id rather
    /// than by prompt (Codex `request_user_input` does; Claude keys by prompt,
    /// so this is `nil` there). Lets a multi-question call resolve each card to
    /// its own answer.
    public let questionID: String?
    public let requestID: String?

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
        multiSelect: Bool = false,
        selectedOptionLabel: String? = nil,
        questionID: String? = nil,
        requestID: String? = nil
    ) {
        self.prompt = prompt
        self.options = options
        self.multiSelect = multiSelect
        self.selectedOptionLabel = selectedOptionLabel
        self.questionID = questionID
        self.requestID = requestID
    }

    private enum CodingKeys: String, CodingKey {
        case prompt
        case options
        case multiSelect = "multi_select"
        case selectedOptionLabel = "selected_option_label"
        case questionID = "question_id"
        case requestID = "request_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        options = try container.decode([Option].self, forKey: .options)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        selectedOptionLabel = try container.decodeIfPresent(String.self, forKey: .selectedOptionLabel)
        questionID = try container.decodeIfPresent(String.self, forKey: .questionID)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
    }
}
