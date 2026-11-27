import Foundation

/// One event in the Feed timeline.
public struct FeedEvent: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A normal agent reply; replying sends a new prompt.
        case agentResponse
        /// An agent question with options to answer inline.
        case question(QuestionPrompt)
        /// A permission request (allow / deny).
        case permission(options: [String])
        /// The agent finished or failed.
        case completion(succeeded: Bool)
    }

    public let id: String
    public var kind: Kind
    public var workspaceID: String
    public var tabID: String
    public var agentName: String
    public var harness: String
    public var markdown: String
    /// The user prompt (or response) this event answers, shown as a quote bubble.
    public var quotedPrompt: String?
    public var createdAt: Date
    public var isResolved: Bool

    public init(
        id: String, kind: Kind, workspaceID: String, tabID: String, agentName: String, harness: String,
        markdown: String, quotedPrompt: String?, createdAt: Date, isResolved: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.agentName = agentName
        self.harness = harness
        self.markdown = markdown
        self.quotedPrompt = quotedPrompt
        self.createdAt = createdAt
        self.isResolved = isResolved
    }
}

/// A question an agent asked (AskUserQuestion), possibly with several items.
public struct QuestionPrompt: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var header: String
        public var question: String
        public var options: [Option]
        public var multiSelect: Bool

        public init(header: String, question: String, options: [Option], multiSelect: Bool = false) {
            self.header = header
            self.question = question
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public struct Option: Hashable, Sendable {
        public var label: String
        public var detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}
