import Foundation

/// Whether `toolName` is one of the agent task tools folded into a workstream
/// checklist rather than reported as anonymous tool telemetry.
///
/// - Parameter toolName: The agent's tool name from the hook payload.
/// - Returns: `true` for `TodoWrite`, `TaskCreate`, and `TaskUpdate`.
public func isWorkstreamTaskTool(_ toolName: String) -> Bool {
    switch toolName {
    case "TodoWrite", "TaskCreate", "TaskUpdate": return true
    default: return false
    }
}

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
/// `TaskCreate` is observed at `PreToolUse`, before Claude has assigned the
/// task an id, so the row is created under a provisional local id. The
/// matching `PostToolUse` carries the tool result, whose `task.id` is
/// authoritative; ``adoptTaskId(fromToolResponse:)`` promotes the provisional
/// row to it. Ids are never guessed from call order, so a create that fails or
/// a session whose counter already ran ahead cannot desynchronize the list.
struct WorkstreamTaskToolTodos: Sendable {
    /// Upper bound on retained tasks, matching the workspace checklist cap so
    /// a long-lived session cannot grow this without bound. Oldest rows are
    /// evicted first.
    static let maxRetainedTodos = 50

    /// Upper bound on remembered owned ids. Larger than ``maxRetainedTodos``
    /// because a task is owned under its provisional id as well as the
    /// authoritative one, and deleted tasks stay owned so their checklist rows
    /// can be retired. Oldest ids are forgotten first; forgetting one only
    /// means a long-since-evicted row is left alone rather than retired.
    static let maxOwnedIds = 200

    private var todos: [WorkstreamTaskTodo] = []
    private var provisionalCounter = 0
    /// Every id this workstream owns, including deleted rows and the
    /// provisional ids their checklist rows were first written under, so the
    /// sync can retire exactly its own stale rows and leave rows owned by
    /// other workstreams alone. Bounded by ``maxOwnedIds``, oldest first.
    private var ownedIdsInOrder: [String] = []
    private var ownedIdSet: Set<String> = []

    /// The ids this workstream currently owns.
    var ownedIds: Set<String> { ownedIdSet }

    /// Ids of rows still awaiting their authoritative id from a tool result,
    /// oldest first.
    private var provisionalIds: [String] = []

    /// Applies one task-tool call observed at `PreToolUse`.
    mutating func apply(toolName: String, toolInputJSON: String?) -> WorkstreamTaskToolOutcome {
        let input = jsonObject(from: toolInputJSON)
        switch toolName {
        case "TodoWrite":
            let parsed = parseWorkstreamTodoWriteList(toolInputJSON)
            guard !parsed.isEmpty else { return .ignored }
            todos = parsed
            provisionalIds.removeAll()
            for todo in parsed { claimId(todo.id) }
            trimToCap()
            return .list(todos)
        case "TaskCreate":
            guard let input, let content = taskContent(in: input) else { return .ignored }
            let id = taskId(in: input) ?? mintProvisionalId()
            claimId(id)
            let state = taskState(in: input) ?? .pending
            upsert(WorkstreamTaskTodo(id: id, content: content, state: state))
            trimToCap()
            return .list(todos)
        case "TaskUpdate":
            guard let input, let id = taskId(in: input) else { return .ignored }
            let raw = taskRawStatus(in: input)
            if raw == "deleted" || raw == "removed" {
                guard todos.contains(where: { $0.id == id }) else { return .ignored }
                todos.removeAll { $0.id == id }
                provisionalIds.removeAll { $0 == id }
                // Deleting the last task is a valid empty transition, not a
                // parse failure: the caller retires this workstream's rows.
                return .list(todos)
            }
            claimId(id)
            guard let index = todos.firstIndex(where: { $0.id == id }) else {
                // Update for a task we never saw created (resumed session, or
                // hooks installed mid-run). Only adoptable with text to show.
                guard let content = taskContent(in: input) else { return .ignored }
                upsert(WorkstreamTaskTodo(
                    id: id,
                    content: content,
                    state: taskState(in: input) ?? .pending
                ))
                trimToCap()
                return .list(todos)
            }
            todos[index] = WorkstreamTaskTodo(
                id: id,
                content: taskContent(in: input) ?? todos[index].content,
                state: taskState(in: input) ?? todos[index].state
            )
            return .list(todos)
        default:
            return .ignored
        }
    }

    /// Promotes the oldest provisional row to the authoritative id Claude
    /// returned in a `TaskCreate` tool result.
    ///
    /// - Parameter json: The raw `tool_response` payload, whose recognized
    ///   shape is `{"task":{"id":"1","subject":"…"}}`.
    /// - Returns: The reconciled list, or `.ignored` when the response carried
    ///   no id or there was no row awaiting one.
    mutating func adoptTaskId(fromToolResponse json: String?) -> WorkstreamTaskToolOutcome {
        guard let root = jsonObject(from: json) else { return .ignored }
        let task = (root["task"] as? [String: Any]) ?? root
        guard let authoritative = taskId(in: task) else { return .ignored }

        if let index = todos.firstIndex(where: { $0.id == authoritative }) {
            // Already reconciled (duplicate delivery). Refresh text if given.
            if let content = taskContent(in: task) {
                todos[index] = WorkstreamTaskTodo(
                    id: authoritative,
                    content: content,
                    state: todos[index].state
                )
            }
            claimId(authoritative)
            return .list(todos)
        }

        let subject = taskContent(in: task)
        let provisional = provisionalIds.first { candidate in
            guard let subject else { return true }
            return todos.first { $0.id == candidate }?.content == subject
        } ?? provisionalIds.first
        guard let provisional,
              let index = todos.firstIndex(where: { $0.id == provisional })
        else { return .ignored }

        todos[index] = WorkstreamTaskTodo(
            id: authoritative,
            content: subject ?? todos[index].content,
            state: todos[index].state
        )
        provisionalIds.removeAll { $0 == provisional }
        // The provisional id stays owned: its checklist row was already
        // written, and only an owned id may be retired, so dropping it here
        // would strand a duplicate row alongside the renamed one.
        claimId(authoritative)
        return .list(todos)
    }

    private mutating func upsert(_ todo: WorkstreamTaskTodo) {
        if let index = todos.firstIndex(where: { $0.id == todo.id }) {
            todos[index] = todo
        } else {
            todos.append(todo)
        }
    }

    /// Records `id` as owned by this workstream, forgetting the oldest ids
    /// past the bound.
    private mutating func claimId(_ id: String) {
        guard ownedIdSet.insert(id).inserted else { return }
        ownedIdsInOrder.append(id)
        guard ownedIdsInOrder.count > Self.maxOwnedIds else { return }
        let overflow = ownedIdsInOrder.count - Self.maxOwnedIds
        for stale in ownedIdsInOrder.prefix(overflow) { ownedIdSet.remove(stale) }
        ownedIdsInOrder.removeFirst(overflow)
    }

    private mutating func mintProvisionalId() -> String {
        provisionalCounter += 1
        // Namespaced so it can never collide with an authoritative Claude id
        // (which is a bare decimal counter).
        let id = "cmux-pending-\(provisionalCounter)"
        provisionalIds.append(id)
        return id
    }

    private mutating func trimToCap() {
        guard todos.count > Self.maxRetainedTodos else { return }
        let dropped = todos.prefix(todos.count - Self.maxRetainedTodos)
        for todo in dropped {
            provisionalIds.removeAll { $0 == todo.id }
        }
        todos.removeFirst(todos.count - Self.maxRetainedTodos)
    }
}

// MARK: - Payload parsing

private func jsonObject(from json: String?) -> [String: Any]? {
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func taskId(in dict: [String: Any]) -> String? {
    for key in ["taskId", "task_id", "id"] {
        if let value = dict[key] as? String, !value.isEmpty { return value }
        if let value = dict[key] as? Int { return String(value) }
    }
    return nil
}

private func taskContent(in dict: [String: Any]) -> String? {
    for key in ["subject", "content", "title", "text", "description"] {
        if let value = dict[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}

private func taskRawStatus(in dict: [String: Any]) -> String? {
    (dict["status"] as? String) ?? (dict["state"] as? String)
}

private func taskState(in dict: [String: Any]) -> WorkstreamTaskTodo.State? {
    guard let raw = taskRawStatus(in: dict) else { return nil }
    switch raw {
    case "completed", "done": return .completed
    case "inProgress", "in_progress", "active": return .inProgress
    case "pending", "todo", "open": return .pending
    // An unrecognized status must not clobber a state we already know; the
    // callers fall back to the existing state, or `.pending` for a new row.
    default: return nil
    }
}

/// Parses the whole-list `TodoWrite` shape (`{"todos":[…]}` or a bare array).
func parseWorkstreamTodoWriteList(_ json: String?) -> [WorkstreamTaskTodo] {
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
              let content = taskContent(in: dict) else { return nil }
        return WorkstreamTaskTodo(
            id: taskId(in: dict) ?? "todo\(idx)",
            content: content,
            state: taskState(in: dict) ?? .pending
        )
    }
}
