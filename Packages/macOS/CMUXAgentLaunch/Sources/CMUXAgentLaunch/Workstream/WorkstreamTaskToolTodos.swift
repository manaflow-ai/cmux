import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Accumulates one workstream's task list from the agent's task-tool calls.
///
/// Claude Code drives its plan through `TaskCreate` / `TaskUpdate`, which
/// mutate **one** task per call and report only that task in the hook payload
/// (older Claude versions, and several other agents, send the whole list in a
/// single `TodoWrite` call instead). The cmux wrapper injects `PreToolUse`
/// with matcher `""`, so every such call reaches us — but only as a delta, so
/// the list has to be carried across events rather than parsed from one
/// payload. See https://github.com/manaflow-ai/cmux/issues/8960.
///
/// `TaskCreate` runs *before* the tool executes, so the payload has no task
/// id yet. Claude numbers tasks sequentially from `"1"` per session, so a
/// created task takes the next id above every id seen so far; a later
/// `TaskUpdate` names its `taskId` explicitly and lines up with it.
public struct WorkstreamTaskToolTodos: Sendable {
    /// Tool names this accumulator understands. Anything else is left to the
    /// generic tool-use telemetry path.
    public static func handles(toolName: String) -> Bool {
        switch toolName {
        case "TodoWrite", "TaskCreate", "TaskUpdate": return true
        default: return false
        }
    }

    private var todos: [WorkstreamTaskTodo] = []
    private var nextSyntheticId = 1

    /// Applies one task-tool call.
    ///
    /// - Returns: The full accumulated list, or `nil` when the payload
    ///   carried nothing usable (so the caller can fall back to plain
    ///   tool-use telemetry rather than publishing an empty checklist).
    mutating func apply(toolName: String, toolInputJSON: String?) -> [WorkstreamTaskTodo]? {
        let input = Self.object(from: toolInputJSON)
        switch toolName {
        case "TodoWrite":
            let parsed = Self.parseTodoWriteList(toolInputJSON)
            guard !parsed.isEmpty else { return nil }
            todos = parsed
            for todo in parsed { reserve(id: todo.id) }
            return todos
        case "TaskCreate":
            guard let input, let content = Self.content(in: input) else { return nil }
            let id = Self.taskId(in: input) ?? mintId()
            reserve(id: id)
            let state = Self.state(in: input) ?? .pending
            if let index = todos.firstIndex(where: { $0.id == id }) {
                todos[index] = WorkstreamTaskTodo(id: id, content: content, state: state)
            } else {
                todos.append(WorkstreamTaskTodo(id: id, content: content, state: state))
            }
            return todos
        case "TaskUpdate":
            guard let input, let id = Self.taskId(in: input) else { return nil }
            reserve(id: id)
            let rawStatus = Self.rawStatus(in: input)
            if rawStatus == "deleted" || rawStatus == "removed" {
                todos.removeAll { $0.id == id }
                // An empty list is a real state here (the agent dropped its
                // last task), but publishing it would blank a checklist that
                // still has user items in it, so report nothing to apply.
                return todos.isEmpty ? nil : todos
            }
            guard let index = todos.firstIndex(where: { $0.id == id }) else {
                // Update for a task we never saw created (resumed session,
                // hook installed mid-run). Only adoptable when the payload
                // also carries text to show.
                guard let content = Self.content(in: input) else { return nil }
                todos.append(WorkstreamTaskTodo(
                    id: id,
                    content: content,
                    state: Self.state(in: input) ?? .pending
                ))
                return todos
            }
            todos[index] = WorkstreamTaskTodo(
                id: id,
                content: Self.content(in: input) ?? todos[index].content,
                state: Self.state(in: input) ?? todos[index].state
            )
            return todos
        default:
            return nil
        }
    }

    private mutating func mintId() -> String {
        let id = String(nextSyntheticId)
        nextSyntheticId += 1
        return id
    }

    /// Keeps the synthetic counter above every id the agent has named, so a
    /// create following an explicitly-numbered task cannot collide with it.
    private mutating func reserve(id: String) {
        guard let numeric = Int(id), numeric >= nextSyntheticId else { return }
        nextSyntheticId = numeric + 1
    }

    // MARK: - Payload parsing

    private static func object(from json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func taskId(in dict: [String: Any]) -> String? {
        for key in ["taskId", "task_id", "id"] {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? Int { return String(value) }
        }
        return nil
    }

    private static func content(in dict: [String: Any]) -> String? {
        for key in ["subject", "content", "title", "text", "description"] {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func rawStatus(in dict: [String: Any]) -> String? {
        (dict["status"] as? String) ?? (dict["state"] as? String)
    }

    private static func state(in dict: [String: Any]) -> WorkstreamTaskTodo.State? {
        guard let raw = rawStatus(in: dict) else { return nil }
        return parseState(raw)
    }

    static func parseState(_ raw: String) -> WorkstreamTaskTodo.State {
        switch raw {
        case "completed", "done": return .completed
        case "inProgress", "in_progress", "active": return .inProgress
        default: return .pending
        }
    }

    /// Parses the whole-list `TodoWrite` shape (`{"todos":[…]}` or a bare
    /// array).
    static func parseTodoWriteList(_ json: String?) -> [WorkstreamTaskTodo] {
        guard let json, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return [] }
        let raw: [Any]
        if let dict = root as? [String: Any] {
            raw = dict["todos"] as? [Any] ?? []
        } else {
            raw = root as? [Any] ?? []
        }
        return raw.enumerated().compactMap { idx, element in
            guard let dict = element as? [String: Any],
                  let content = content(in: dict) else { return nil }
            return WorkstreamTaskTodo(
                id: taskId(in: dict) ?? "todo\(idx)",
                content: content,
                state: state(in: dict) ?? .pending
            )
        }
    }
}

extension WorkstreamTaskTodo {
    /// A stable checklist identity for this todo inside `workstreamId`.
    ///
    /// Agent task ids are per-session counters (`"1"`, `"2"`, …) while the
    /// workspace checklist is keyed by `UUID`, so the pair is hashed into a
    /// deterministic UUID. Deriving it (instead of keeping a side table)
    /// means the same task keeps its checklist row across app restarts and
    /// across every entrypoint that syncs the list.
    public func stableChecklistItemId(workstreamId: String) -> UUID {
        Self.derivedUUID(from: "cmux.workstream.todo\u{0}\(workstreamId)\u{0}\(id)")
    }

    static func derivedUUID(from seed: String) -> UUID {
        let data = Data(seed.utf8)
        var bytes: [UInt8]
        #if canImport(CryptoKit)
        bytes = Array(SHA256.hash(data: data).prefix(16))
        #else
        bytes = Array(repeating: 0, count: 16)
        for (index, byte) in data.enumerated() {
            bytes[index % 16] = bytes[index % 16] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        #endif
        // RFC 4122 version 4 / variant bits so the value is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
