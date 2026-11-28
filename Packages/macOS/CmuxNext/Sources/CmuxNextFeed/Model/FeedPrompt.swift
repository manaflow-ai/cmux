public import Foundation

/// The typed prompt of an item, one case per built-in kind (feed.md 3.4)
/// plus custom kinds that carry their own answer schema. A notice has no
/// prompt.
public nonisolated enum FeedPrompt: Sendable, Equatable {
    case notice
    case question(Question)
    case choice(Choice)
    case approve(Approve)
    case confirm(Confirm)
    case signIn(SignIn)
    case passkey(Passkey)
    case review(Review)
    case input(Input)
    case file(File)
    case handoff(Handoff)
    /// `x-<publisher>.<name>`; the generic renderer shows title, body and actions.
    case custom(kind: String, prompt: FeedJSON, answerSchema: FeedJSON?)

    /// The registry kind name.
    public var kind: String {
        switch self {
        case .notice: "notice"
        case .question: "question"
        case .choice: "choice"
        case .approve: "approve"
        case .confirm: "confirm"
        case .signIn: "sign-in"
        case .passkey: "passkey"
        case .review: "review"
        case .input: "input"
        case .file: "file"
        case .handoff: "handoff"
        case let .custom(kind, _, _): kind
        }
    }

    public var isNotice: Bool { self == .notice }

    /// Only a Mac can answer it (the browser pane holds the tab).
    public var needsMac: Bool {
        switch self {
        case .signIn, .passkey: true
        default: false
        }
    }

    /// The kind's default priority (feed.md 3.4 table).
    public var defaultPriority: FeedPriority {
        switch self {
        case .notice, .review, .custom: .normal
        default: .high
        }
    }
}

extension FeedPrompt {
    public nonisolated struct Question: Sendable, Equatable {
        public var question: String
        public var suggestions: [String]
        public var multiline: Bool

        public init(question: String, suggestions: [String] = [], multiline: Bool = false) {
            self.question = question
            self.suggestions = suggestions
            self.multiline = multiline
        }
    }

    /// One to four questions, each with two to eight options.
    public nonisolated struct Choice: Sendable, Equatable {
        public var questions: [ChoiceQuestion]

        public init(questions: [ChoiceQuestion]) {
            self.questions = questions
        }
    }

    public nonisolated struct ChoiceQuestion: Sendable, Equatable, Identifiable {
        public var id: String
        public var question: String
        public var header: String?
        public var options: [ChoiceOption]
        public var multi: Bool
        public var allowOther: Bool

        public init(id: String, question: String, header: String? = nil, options: [ChoiceOption], multi: Bool = false, allowOther: Bool = false) {
            self.id = id
            self.question = question
            self.header = header
            self.options = options
            self.multi = multi
            self.allowOther = allowOther
        }
    }

    public nonisolated struct ChoiceOption: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var detail: String?

        public init(id: String, label: String, detail: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
        }
    }

    public nonisolated struct Approve: Sendable, Equatable {
        public enum ActionType: String, Sendable, Equatable {
            case command, edit, tool, network, install, custom
        }

        public struct Action: Sendable, Equatable {
            public var type: ActionType
            public var summary: String
            public var command: String?
            public var cwd: String?
            public var tool: String?
            /// The attachment id of the diff (edits).
            public var diff: String?
            public var risk: String?

            public init(type: ActionType, summary: String, command: String? = nil, cwd: String? = nil,
                        tool: String? = nil, diff: String? = nil, risk: String? = nil) {
                self.type = type
                self.summary = summary
                self.command = command
                self.cwd = cwd
                self.tool = tool
                self.diff = diff
                self.risk = risk
            }
        }

        public var action: Action
        public var scopes: [FeedApproveScope]

        public init(action: Action, scopes: [FeedApproveScope] = [.once]) {
            self.action = action
            self.scopes = scopes.isEmpty ? [.once] : scopes
        }
    }

    public nonisolated struct Confirm: Sendable, Equatable {
        public var statement: String
        public var confirmLabel: String?
        public var cancelLabel: String?
        public var destructive: Bool

        public init(statement: String, confirmLabel: String? = nil, cancelLabel: String? = nil, destructive: Bool = false) {
            self.statement = statement
            self.confirmLabel = confirmLabel
            self.cancelLabel = cancelLabel
            self.destructive = destructive
        }
    }

    public nonisolated struct SignIn: Sendable, Equatable {
        public var origin: String
        public var url: URL?
        public var browserTab: String
        public var reason: String

        public init(origin: String, url: URL? = nil, browserTab: String, reason: String) {
            self.origin = origin
            self.url = url
            self.browserTab = browserTab
            self.reason = reason
        }
    }

    public nonisolated struct Passkey: Sendable, Equatable {
        public enum Ceremony: String, Sendable, Equatable { case get, create }
        public var origin: String
        public var rpID: String?
        public var ceremony: Ceremony
        public var browserTab: String
        public var reason: String

        public init(origin: String, rpID: String? = nil, ceremony: Ceremony = .get, browserTab: String, reason: String) {
            self.origin = origin
            self.rpID = rpID
            self.ceremony = ceremony
            self.browserTab = browserTab
            self.reason = reason
        }
    }
}
