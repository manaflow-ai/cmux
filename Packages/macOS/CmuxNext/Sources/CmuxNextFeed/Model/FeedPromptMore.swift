public import Foundation

extension FeedPrompt {
    public nonisolated struct Review: Sendable, Equatable {
        public enum Subject: String, Sendable, Equatable { case diff, pr, file, document, url, plan }
        public var subject: Subject
        /// The reviewed thing: an attachment id, a URL, a path, or inline text (plans).
        public var ref: String
        public var checklist: [String]

        public init(subject: Subject, ref: String, checklist: [String] = []) {
            self.subject = subject
            self.ref = ref
            self.checklist = checklist
        }
    }

    /// A flat form (MCP elicitation).
    public nonisolated struct Input: Sendable, Equatable {
        public var fields: [InputField]

        public init(fields: [InputField]) {
            self.fields = fields
        }
    }

    public nonisolated struct InputField: Sendable, Equatable, Identifiable {
        public enum FieldType: Sendable, Equatable {
            case string(format: String?)
            case number
            case integer
            case boolean
            case choice([String])
        }

        public var id: String
        public var title: String
        public var type: FieldType
        public var required: Bool

        public init(id: String, title: String, type: FieldType = .string(format: nil), required: Bool = false) {
            self.id = id
            self.title = title
            self.type = type
            self.required = required
        }
    }

    public nonisolated struct File: Sendable, Equatable {
        public var purpose: String
        public var accept: [String]
        public var multiple: Bool
        public var maxBytes: Int

        public init(purpose: String, accept: [String] = [], multiple: Bool = false, maxBytes: Int = 50 << 20) {
            self.purpose = purpose
            self.accept = accept
            self.multiple = multiple
            self.maxBytes = maxBytes
        }
    }

    public nonisolated struct Handoff: Sendable, Equatable {
        public var reason: String
        public var resumeHint: String?

        public init(reason: String, resumeHint: String? = nil) {
            self.reason = reason
            self.resumeHint = resumeHint
        }
    }
}

/// How long an `approve` answer holds.
public nonisolated enum FeedApproveScope: String, Sendable, Equatable, Hashable, CaseIterable {
    case once
    case session
    case always
}

/// A small JSON value: custom prompts, schemas, action answers, input forms.
public nonisolated enum FeedJSON: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FeedJSON])
    case object([String: FeedJSON])

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}
