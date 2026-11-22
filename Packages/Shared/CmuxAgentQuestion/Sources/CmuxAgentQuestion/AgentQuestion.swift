public import Foundation

/// A question an agent asks a person, independent of the harness that asked.
///
/// One `AgentQuestion` holds one ask: one to four items (Claude Code asks up
/// to four questions in one tool call), each with options, optional
/// multi-select and an optional free-text "Other" answer. The asking harness
/// is recorded in `source`, so an answer can be encoded back into that
/// harness's own response shape (`AgentQuestionAnswer.permissionResponse`).
public struct AgentQuestion: Hashable, Sendable, Codable, Identifiable {
    /// Stable id of the ask: the acpmux permission id, or the conversation
    /// part id for a question posted in Home.
    public var id: String
    public var source: Source
    public var items: [Item]
    public var state: State

    public init(id: String, source: Source, items: [Item], state: State = .pending) {
        self.id = id
        self.source = source
        self.items = items
        self.state = state
    }

    /// The first item's prompt, for notifications, previews and search.
    public var summary: String { items.first?.prompt ?? "" }

    public var isPending: Bool { state == .pending }
}

extension AgentQuestion {
    /// Who asked, and where the answer goes.
    public struct Source: Hashable, Sendable, Codable {
        public var harness: Harness
        /// acpmux session id (the agent tab or the Chief's session).
        public var session: String
        /// acpmux permission id; the answer goes to `_acpmux/permission_respond`.
        public var permission: String?
        /// The harness's tool call id, when it has one.
        public var toolCall: String?
        /// The display name of the asking agent ("Claude Code", "Chief").
        public var agentName: String?
        /// The permission option that submits answers (`allow_once`).
        public var answerOption: String?
        /// The permission option that declines the ask (`reject_once`).
        public var rejectOption: String?

        public init(harness: Harness, session: String, permission: String? = nil, toolCall: String? = nil, agentName: String? = nil) {
            self.harness = harness
            self.session = session
            self.permission = permission
            self.toolCall = toolCall
            self.agentName = agentName
        }
    }

    /// The asking harness. It decides the answer's wire shape.
    public enum Harness: String, Hashable, Sendable, Codable, CaseIterable {
        /// Claude Code's AskUserQuestion: answers keyed by question text.
        case claude
        /// A Codex user-input request: answers keyed by question id.
        case codex
        /// Any other ACP agent: the selected option id answers it.
        case acp
        /// The Chief, asking in a Home conversation.
        case chief
    }

    /// One question of an ask.
    public struct Item: Hashable, Sendable, Codable, Identifiable {
        /// Stable within the ask: the harness's id, else `q<index>`.
        public var id: String
        /// A short label shown as a chip above the prompt ("Auth method").
        public var header: String?
        public var prompt: String
        public var options: [Option]
        public var multiSelect: Bool
        /// Whether the person may type an answer that is not an option.
        public var allowsOther: Bool

        public init(id: String, header: String? = nil, prompt: String, options: [Option], multiSelect: Bool = false, allowsOther: Bool = true) {
            self.id = id
            self.header = header
            self.prompt = prompt
            self.options = options
            self.multiSelect = multiSelect
            self.allowsOther = allowsOther
        }

        /// True when at least one option carries a preview: the card then
        /// shows the highlighted option's preview beside the list.
        public var hasPreviews: Bool { options.contains { $0.preview != nil } }
    }

    public struct Option: Hashable, Sendable, Codable, Identifiable {
        /// Stable within its item: the harness's option id, else the label.
        public var id: String
        public var label: String
        public var detail: String?
        public var preview: Preview?

        public init(id: String, label: String, detail: String? = nil, preview: Preview? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
            self.preview = preview
        }
    }

    /// Content shown beside the options while one is highlighted (a code
    /// sample, a layout sketch, a diff).
    public struct Preview: Hashable, Sendable, Codable {
        public enum Format: String, Hashable, Sendable, Codable { case markdown, monospace }
        public var text: String
        public var format: Format

        public init(text: String, format: Format = .monospace) {
            self.text = text
            self.format = format
        }
    }

    /// Where the ask stands. Only the owner (acpmux or the conversation
    /// owner) moves it out of `pending`; clients render it.
    /// Wire shape `{"kind": "pending" | "answered" | "cancelled", "answer"?: AgentQuestionAnswer}`.
    public enum State: Hashable, Sendable, Codable {
        case pending
        case answered(AgentQuestionAnswer)
        /// The turn was cancelled, the agent stopped, or the person declined.
        case cancelled

        private enum CodingKeys: String, CodingKey { case kind, answer }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "answered": self = .answered(try container.decode(AgentQuestionAnswer.self, forKey: .answer))
            case "cancelled": self = .cancelled
            default: self = .pending
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pending: try container.encode("pending", forKey: .kind)
            case .cancelled: try container.encode("cancelled", forKey: .kind)
            case .answered(let answer):
                try container.encode("answered", forKey: .kind)
                try container.encode(answer, forKey: .answer)
            }
        }
    }
}

extension AgentQuestion.Item {
    private enum CodingKeys: String, CodingKey { case id, header, prompt, options, multiSelect, allowsOther }

    /// `multiSelect` defaults to false and `allowsOther` to true when absent,
    /// so other writers (the daemon, the web gallery) may omit them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            header: try container.decodeIfPresent(String.self, forKey: .header),
            prompt: try container.decode(String.self, forKey: .prompt),
            options: try container.decodeIfPresent([AgentQuestion.Option].self, forKey: .options) ?? [],
            multiSelect: try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false,
            allowsOther: try container.decodeIfPresent(Bool.self, forKey: .allowsOther) ?? true
        )
    }
}

extension AgentQuestion {
    /// Plain text for transcripts that cannot host the card (search,
    /// notifications, a placeholder row): each prompt with its numbered
    /// options, or with the chosen answers once answered.
    public var transcriptText: String {
        items.map { item in
            switch state {
            case .answered(let answer):
                return "\(item.prompt)\n✓ \(labels(item, answer.selections[item.id]).joined(separator: ", "))"
            case .pending, .cancelled:
                let options = item.options.enumerated().map { "\($0 + 1). \($1.label)" }
                return ([item.prompt] + options).joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }
}
