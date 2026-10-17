public import Foundation

/// A user choice offered by a provider question.
public struct ConversationQuestionOption: Codable, Hashable, Sendable, Identifiable {
    /// Stable option identifier.
    public let id: String
    /// Visible label.
    public let label: String
    /// Optional explanatory text.
    public let detail: String?
    /// Creates a question option.
    public init(id: String, label: String, detail: String? = nil) { self.id = id; self.label = label; self.detail = detail }
}

/// A blocking approval request.
public struct ConversationApproval: Codable, Hashable, Sendable {
    /// Requested action summary.
    public let summary: String
    /// Exact command or action, when available.
    public let command: String?
    /// Whether an always-allow decision is offered by the provider.
    public let supportsAlwaysAllow: Bool
    /// Creates approval details.
    public init(summary: String, command: String? = nil, supportsAlwaysAllow: Bool = false) { self.summary = summary; self.command = command; self.supportsAlwaysAllow = supportsAlwaysAllow }
}

/// A blocking question request.
public struct ConversationQuestion: Codable, Hashable, Sendable {
    /// Prompt category.
    public let category: String?
    /// Bold question text.
    public let prompt: String
    /// Available choices.
    public let options: [ConversationQuestionOption]
    /// Whether a free-form answer is accepted.
    public let allowsCustomAnswer: Bool
    /// Whether the provider requires free-form input to be visually concealed.
    /// Optional for compatibility with journals written before this flag existed.
    public let isSecret: Bool?
    /// Current question index in a multi-question request.
    public let index: Int?
    /// Total questions in this request.
    public let total: Int?
    /// Creates question details.
    public init(category: String? = nil, prompt: String, options: [ConversationQuestionOption] = [], allowsCustomAnswer: Bool = true, isSecret: Bool? = nil, index: Int? = nil, total: Int? = nil) { self.category = category; self.prompt = prompt; self.options = options; self.allowsCustomAnswer = allowsCustomAnswer; self.isSecret = isSecret; self.index = index; self.total = total }
}

/// One answer in a potentially multi-question provider request.
public struct ConversationQuestionAnswer: Codable, Hashable, Sendable {
    /// Question index.
    public let index: Int
    /// Selected option identifier, when one was selected.
    public let optionID: String?
    /// Free-form answer, when supplied.
    public let text: String?
    /// Creates a question answer.
    public init(index: Int, optionID: String? = nil, text: String? = nil) { self.index = index; self.optionID = optionID; self.text = text }
}

/// Lifecycle state for a provider request.
public enum ConversationRequestState: String, Codable, Hashable, Sendable { case pending, answered, approved, denied, skipped, stale, cancelled }

/// An approval or question that must be resolved by the user.
public struct ConversationRequest: Codable, Hashable, Sendable, Identifiable {
    /// Stable request identity.
    public let id: ConversationRequestID
    /// Owning turn.
    public let turnID: ConversationTurnID?
    /// Generation in which this request is valid.
    public let generation: ConversationGeneration
    /// Request kind.
    public let kind: String
    /// Lifecycle state.
    public var state: ConversationRequestState
    /// Approval details when `kind` is approval.
    public let approval: ConversationApproval?
    /// Question details when `kind` is question.
    public let question: ConversationQuestion?
    /// Original provider payload.
    public let rawPayload: ConversationJSONValue?
    /// Creates a provider request.
    public init(id: ConversationRequestID, turnID: ConversationTurnID? = nil, generation: ConversationGeneration, kind: String, state: ConversationRequestState = .pending, approval: ConversationApproval? = nil, question: ConversationQuestion? = nil, rawPayload: ConversationJSONValue? = nil) { self.id = id; self.turnID = turnID; self.generation = generation; self.kind = kind; self.state = state; self.approval = approval; self.question = question; self.rawPayload = rawPayload }
}

/// A queued user turn awaiting the current run.
public struct ConversationQueueItem: Codable, Hashable, Sendable, Identifiable {
    /// Stable queue item identity.
    public let id: ConversationItemID
    /// Durable command that created the queue item.
    public let commandID: ConversationCommandID
    /// Draft text.
    public var text: String
    /// Queue position, starting at zero.
    public var position: Int
    /// Whether the item is currently being delivered.
    public var isDelivering: Bool
    /// Creates a queued turn.
    public init(id: ConversationItemID, commandID: ConversationCommandID, text: String, position: Int, isDelivering: Bool = false) { self.id = id; self.commandID = commandID; self.text = text; self.position = position; self.isDelivering = isDelivering }
}
