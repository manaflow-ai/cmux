/// A multiple-choice question the agent asked the user.
///
/// Sourced from `AskUserQuestion`-style tool invocations. Options render as
/// in-card buttons; a free-text reply through the composer is always
/// available as well.
public struct ChatQuestion: Sendable, Equatable, Codable {
    /// One selectable answer.
    public struct Option: Sendable, Equatable, Codable, Identifiable {
        /// Stable provider identity within the question.
        public let id: String

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
            self.id = id ?? label
            self.label = label
            self.detail = detail
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case label
            case detail
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let label = try container.decode(String.self, forKey: .label)
            self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? label
            self.label = label
            self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        }
    }

    /// The question text.
    public let prompt: String

    /// The selectable answers, in display order.
    public let options: [Option]

    /// The label of the chosen option once answered, `nil` while pending.
    public var selectedOptionLabel: String? {
        selectedOptionLabels.isEmpty ? nil : selectedOptionLabels.joined(separator: ", ")
    }

    /// All selected labels. A single-select question contains zero or one
    /// value; multi-select questions can contain several values.
    public let selectedOptionLabels: [String]

    /// Whether the provider permits selecting more than one option.
    public let multiSelect: Bool

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
        questionID: String? = nil,
        selectedOptionLabels: [String]? = nil,
        multiSelect: Bool = false
    ) {
        self.prompt = prompt
        self.options = options
        self.selectedOptionLabels = selectedOptionLabels
            ?? selectedOptionLabel.map { [$0] }
            ?? []
        self.multiSelect = multiSelect
        self.questionID = questionID
    }

    private enum CodingKeys: String, CodingKey {
        case prompt
        case options
        case selectedOptionLabel = "selected_option_label"
        case selectedOptionLabels = "selected_option_labels"
        case multiSelect = "multi_select"
        case questionID = "question_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.options = try container.decode([Option].self, forKey: .options)
        let legacyLabel = try container.decodeIfPresent(String.self, forKey: .selectedOptionLabel)
        self.selectedOptionLabels = try container.decodeIfPresent([String].self, forKey: .selectedOptionLabels)
            ?? legacyLabel.map { [$0] }
            ?? []
        self.multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        self.questionID = try container.decodeIfPresent(String.self, forKey: .questionID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(selectedOptionLabel, forKey: .selectedOptionLabel)
        try container.encode(selectedOptionLabels, forKey: .selectedOptionLabels)
        try container.encode(multiSelect, forKey: .multiSelect)
        try container.encodeIfPresent(questionID, forKey: .questionID)
    }
}
