import Foundation

/// A repository checkpoint the Mac recorded around a turn (the cmux app's
/// `git.checkpoint.*` records, webviews acpmux/checkpoints).
public struct AgentCheckpoint: Identifiable, Hashable, Sendable {
    public var id: String
    /// The prompt of the turn it brackets.
    public var title: String
    public var turnID: String?
    /// Before or after the turn ran.
    public var isBeforeTurn: Bool
    public var createdAt: Date
    public var branch: String?
    /// Short commit the working tree was based on.
    public var head: String?
    public var files: Int
    /// False when files were left out (too large, ignored).
    public var complete: Bool
    public var skipped: Int
    /// A row title that replaces "Before/After “title”" (a safety checkpoint before a restore).
    public var caption: String?

    public init(id: String, title: String, turnID: String? = nil, isBeforeTurn: Bool = true, createdAt: Date, branch: String? = nil,
                head: String? = nil, files: Int, complete: Bool = true, skipped: Int = 0, caption: String? = nil) {
        self.caption = caption
        self.id = id
        self.title = title
        self.turnID = turnID
        self.isBeforeTurn = isBeforeTurn
        self.createdAt = createdAt
        self.branch = branch
        self.head = head
        self.files = files
        self.complete = complete
        self.skipped = skipped
    }
}

/// Where a session can continue (`_acpmux/harnesses`).
public struct AgentHandoffTarget: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var family: String?
    /// Why it can't take the session (not installed, signed out); nil when it can.
    public var unavailableReason: String?

    public init(id: String, name: String, family: String? = nil, unavailableReason: String? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.unavailableReason = unavailableReason
    }
}

/// A prepared continuation (`_acpmux/handoff_prepare`): the context capsule
/// the target starts from and what it carries.
public struct AgentHandoffDraft: Identifiable, Hashable, Sendable {
    public struct Coverage: Hashable, Sendable, Identifiable {
        public enum Status: String, Hashable, Sendable { case included, summarized, omitted, unavailable }
        public var id: String { item }
        public var item: String
        public var status: Status
        public var detail: String?

        public init(item: String, status: Status, detail: String? = nil) {
            self.item = item
            self.status = status
            self.detail = detail
        }

        public var title: String {
            switch item {
            case "transcript": "Transcript"
            case "tool_output": "Tool output"
            case "plan": "Plan"
            case "files": "Files"
            case "memory": "Memory"
            case "checkpoint": "Repository checkpoint"
            case "model": "Model"
            default: item.capitalized
            }
        }
    }

    public var id: String
    public var revision: Int
    public var target: AgentHandoffTarget
    public var capsule: String
    public var maxBytes: Int
    public var coverage: [Coverage]
    public var checkpointReference: String?
    public var promptID: String?

    public init(id: String, revision: Int, target: AgentHandoffTarget, capsule: String, maxBytes: Int = 65536,
                coverage: [Coverage], checkpointReference: String? = nil, promptID: String? = nil) {
        self.id = id
        self.revision = revision
        self.target = target
        self.capsule = capsule
        self.maxBytes = maxBytes
        self.coverage = coverage
        self.checkpointReference = checkpointReference
        self.promptID = promptID
    }
}

/// The continuation started: the new session on the target harness.
public struct AgentHandoffReceipt: Hashable, Sendable {
    public var targetSessionID: String
    public var targetName: String

    public init(targetSessionID: String, targetName: String) {
        self.targetSessionID = targetSessionID
        self.targetName = targetName
    }
}

/// A parity feature the connected Mac doesn't offer over the link, with the sentence to show.
public struct AgentFeatureUnavailable: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A chat's session status, as the Mac's Session status card shows it (`/status`,
/// webviews acpmux/HarnessStatusCard): acpmux's detail of the session, one labeled value
/// per field, "Not reported" where acpmux left it out. No value is ever a credential:
/// only the agent's own auth-source label is read.
public struct AgentSessionStatus: Hashable, Sendable {
    public struct Field: Hashable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The agent's name over the card's title (the harness).
    public var harness: String
    public var fields: [Field]

    public init(harness: String, fields: [Field]) {
        self.harness = harness
        self.fields = fields
    }

    /// The text Copy All puts on the clipboard: one `label: value` line per field.
    public var copyText: String {
        fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}
