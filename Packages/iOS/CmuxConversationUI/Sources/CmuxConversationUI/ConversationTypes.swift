import CmuxConversation
import Foundation

/// A workspace offered by the current host when creating a task.
public struct ConversationWorkspaceChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let directory: String

    public init(id: String, title: String, directory: String) {
        self.id = id
        self.title = title
        self.directory = directory
    }
}

/// A UI-facing connection state. Host stream failures retain the transcript
/// and pending requests while disabling unsafe commands.
public enum ConversationConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(message: String)
}

public extension ConversationProvider {
    /// Human-readable provider label.
    var displayName: String {
        switch self {
        case .codex: ConversationL10n.value("conversation.codex", "Codex")
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode"
        case .unknown(let value): value
        }
    }
}

public extension ConversationSession {
    /// A short workspace subtitle for task rows and the conversation header.
    var workspaceDisplayName: String { directory.isEmpty ? workspaceID : directory }
}

public extension ConversationItem {
    /// Text suitable for a simple transcript row.
    var displayText: String { text ?? tool?.name ?? plan?.text ?? diff?.text ?? artifact?.fileName ?? rawPayload?.prettyDescription ?? "" }

    /// A compact title for a tool or structured item.
    var displayTitle: String {
        switch kind {
        case .tool: tool?.name ?? "Tool"
        case .result: "Result"
        case .reasoning: "Thinking"
        case .plan: "Plan"
        case .files: diff?.path ?? ConversationL10n.value("conversation.files", "Files")
        case .artifact: artifact?.fileName ?? "Artifact"
        default: kind.rawValue.capitalized
        }
    }
}

public extension ConversationRequest {
    /// Whether this request replaces the composer.
    var isBlocking: Bool { state == .pending && (kind == "approval" || kind == "question" || kind == "ask_user") }
}

public extension ConversationJSONValue {
    /// Compact text for a monospace tool card.
    var prettyDescription: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return "[\n" + values.map { "  \($0.prettyDescription)" }.joined(separator: ",\n") + "\n]"
        case .object(let values):
            let lines = values.keys.sorted().map { key in "\"\(key)\": \(values[key]?.prettyDescription ?? "null")" }
            return "{\n" + lines.map { "  \($0)" }.joined(separator: ",\n") + "\n}"
        }
    }
}
