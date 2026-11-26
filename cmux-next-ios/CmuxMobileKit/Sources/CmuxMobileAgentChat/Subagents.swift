import Foundation

/// A subagent a session started (acpmux `_meta.acpmux.subagents`, see
/// cmux-tui/crates/acpmux/src/subagents.rs): native ACP subagent sessions and
/// Codex collaboration calls alike. `items` is its own transcript.
public struct AgentSubagent: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case running, completed, failed, cancelled, disconnected

        public var label: String {
            switch self {
            case .running: "Running"
            case .completed: "Done"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .disconnected: "Disconnected"
            }
        }
    }

    public var id: String
    /// The subagent that spawned it, or nil for the session's own.
    public var parent: String?
    public var name: String
    public var task: String?
    public var state: State
    public var startedAt: Date
    public var endedAt: Date?
    /// The title of its latest tool call.
    public var action: String?
    /// The turn it was spawned in (top-level subagents).
    public var turnID: String?
    public var items: [TurnItem] = []

    public init(id: String, parent: String?, name: String, task: String? = nil, state: State = .running,
                startedAt: Date, turnID: String? = nil) {
        self.id = id
        self.parent = parent
        self.name = name
        self.task = task
        self.state = state
        self.startedAt = startedAt
        self.turnID = turnID
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// Its transcript as a turn, so the chat's row rules (tool groups, edits) apply.
    public var asTurn: AgentTurn {
        var turn = AgentTurn(id: "sub-\(id)", prompt: task ?? name, promptAt: startedAt)
        turn.items = items
        turn.status = state == .running ? .running : (state == .completed ? .completed : .failed)
        turn.startedAt = startedAt
        turn.endedAt = endedAt
        return turn
    }
}

/// One `_meta.acpmux.subagents` entry: a subagent started or changed.
public struct AgentSubagentChange: Hashable, Sendable {
    public var id: String
    public var parent: String?
    public var name: String?
    public var task: String?
    public var state: AgentSubagent.State?
    /// The tool call that started it (drawn by the subagent row instead).
    public var toolCallID: String?
    public var at: Date

    public init(id: String, parent: String? = nil, name: String? = nil, task: String? = nil, state: AgentSubagent.State? = nil,
                toolCallID: String? = nil, at: Date = Date()) {
        self.id = id
        self.parent = parent
        self.name = name
        self.task = task
        self.state = state
        self.toolCallID = toolCallID
        self.at = at
    }

    /// Decodes one entry of `_meta.acpmux.subagents`.
    public init?(_ value: JSONValue, at: Date) {
        guard let id = value["id"]?.stringValue else { return nil }
        let text = { (key: String) -> String? in
            guard let string = value[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
            return string
        }
        self.init(id: id, parent: text("parent"), name: text("name"), task: text("task") ?? text("prompt"),
                  state: text("state").flatMap(AgentSubagent.State.init(rawValue:)), toolCallID: text("toolCallId"), at: at)
    }
}

extension Array where Element == TurnItem {
    /// Appends a streamed update to a transcript (a subagent's own items).
    mutating func apply(_ update: ACPSessionUpdate) {
        switch update {
        case .agentMessageChunk(let text, let messageId):
            if case .message(let id, let existing)? = last, messageId == nil || messageId == id {
                self[count - 1] = .message(id: id, markdown: existing + text)
            } else {
                append(.message(id: messageId ?? UUID().uuidString, markdown: text))
            }
        case .agentThoughtChunk(let text):
            if case .thought(let id, let existing)? = last {
                self[count - 1] = .thought(id: id, text: existing + text)
            } else {
                append(.thought(id: UUID().uuidString, text: text))
            }
        case .toolCall(var call):
            call.startedAt = call.startedAt ?? Date()
            if let index = lastIndex(where: { if case .tool(let existing) = $0 { existing.id == call.id } else { false } }) {
                self[index] = .tool(call)
            } else {
                append(.tool(call))
            }
        case .toolCallUpdate(let update):
            if let index = lastIndex(where: { if case .tool(let existing) = $0 { existing.id == update.toolCallId } else { false } }),
               case .tool(var call) = self[index] {
                call.apply(update)
                if !call.isRunning, call.endedAt == nil { call.endedAt = Date() }
                self[index] = .tool(call)
            }
        case .plan(let entries):
            if let index = firstIndex(where: { if case .plan = $0 { true } else { false } }), case .plan(let id, _) = self[index] {
                self[index] = .plan(id: id, entries: entries)
            } else if !entries.isEmpty {
                append(.plan(id: UUID().uuidString, entries: entries))
            }
        default:
            break
        }
    }
}
