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
/// single `TodoWrite` call instead), so the list has to be carried across
/// events rather than parsed from one payload.
/// See https://github.com/manaflow-ai/cmux/issues/8960.
///
/// Every mutation is applied from `PostToolUse`, never `PreToolUse`. A
/// pre-execution event only says the agent *intends* a change: a create that
/// is denied or errors would leave a permanent phantom row, and a speculative
/// delete would drop a checklist row that still exists. `PostToolUse` fires
/// only after the tool ran, and its `tool_response` carries the authoritative
/// task id — which `TaskCreate` has no way to report beforehand, since Claude
/// assigns it during execution. Nothing here infers an id from call order.
///
/// A `TaskUpdate` payload that also describes the task lets a resumed session
/// re-adopt tasks created before cmux was watching, so the list recovers
/// instead of silently ignoring deltas for ids it never saw.
struct WorkstreamTaskToolTodos: Sendable {
    /// Upper bound on retained tasks, matching the workspace checklist cap so
    /// a long-lived session cannot grow this without bound. Oldest rows are
    /// evicted first.
    static let maxRetainedTodos = 50

    /// Upper bound on remembered owned ids. Larger than ``maxRetainedTodos``
    /// because deleted tasks stay owned so their checklist rows can still be
    /// retired. Oldest ids are forgotten first; forgetting one only means a
    /// long-since-evicted row is left alone rather than retired.
    static let maxOwnedIds = 200

    private var todos: [WorkstreamTaskTodo] = []

    /// Every id this workstream owns, including tasks it has since deleted, so
    /// the sync can retire exactly its own stale rows and leave rows owned by
    /// other workstreams alone. Bounded by ``maxOwnedIds``, oldest first.
    private var ownedIdsInOrder: [String] = []
    private var ownedIdSet: Set<String> = []

    /// The ids this workstream currently owns.
    var ownedIds: Set<String> { ownedIdSet }

    /// Whether anything has been accumulated yet.
    var isEmpty: Bool { todos.isEmpty && ownedIdSet.isEmpty }

    /// Restores a task list recovered from persisted checklist rows.
    ///
    /// Used after an app restart, a dropped event, or eviction, so an ordinary
    /// status-only `TaskUpdate` finds its row instead of being ignored as an
    /// unknown id.
    ///
    /// - Parameter restored: The tasks recovered for this workstream, in
    ///   display order.
    mutating func seed(with restored: [WorkstreamTaskTodo]) {
        todos = restored
        for todo in restored { claimId(todo.id) }
        trimToCap()
    }

    /// Applies one **completed** task-tool call.
    ///
    /// - Parameters:
    ///   - toolName: The agent's tool name.
    ///   - toolInputJSON: The tool's request payload.
    ///   - toolResponseJSON: The tool's result payload, which is where an id
    ///     assigned during execution appears.
    ///   - isError: Whether the agent reported the call as failed. Failed calls
    ///     never mutate the list.
    /// - Returns: The workstream's task list, or ``WorkstreamTaskToolOutcome/ignored``
    ///   when the payloads carried nothing usable.
    mutating func apply(
        toolName: String,
        toolInputJSON: String?,
        toolResponseJSON: String?,
        isError: Bool
    ) -> WorkstreamTaskToolOutcome {
        guard !isError else { return .ignored }
        let input = jsonObject(from: toolInputJSON)
        let response = jsonObject(from: toolResponseJSON)
        // Claude nests the task under "task"; tolerate a flat result too.
        let resultTask = (response?["task"] as? [String: Any]) ?? response

        switch toolName {
        case "TodoWrite":
            // An empty list is a real transition (the agent cleared its plan),
            // distinct from a payload that carried no list at all.
            guard let parsed = parseWorkstreamTodoWriteSnapshot(toolInputJSON) else {
                return .ignored
            }
            todos = parsed
            // Ids accumulate across snapshots: a task dropped from a later
            // whole-list report must stay owned so its row can be retired.
            for todo in parsed { claimId(todo.id) }
            trimToCap()
            return .list(todos)

        case "TaskCreate":
            // The id exists only in the result; without it there is nothing a
            // later TaskUpdate could ever address.
            guard let id = resultTask.flatMap(taskId(in:)) else { return .ignored }
            guard let content = resultTask.flatMap(taskContent(in:))
                ?? input.flatMap(taskContent(in:)) else { return .ignored }
            claimId(id)
            let state = resultTask.flatMap(taskState(in:))
                ?? input.flatMap(taskState(in:))
                ?? .pending
            upsert(WorkstreamTaskTodo(id: id, content: content, state: state))
            trimToCap()
            return .list(todos)

        case "TaskUpdate":
            guard let id = input.flatMap(taskId(in:)) ?? resultTask.flatMap(taskId(in:)) else {
                return .ignored
            }
            let rawStatus = input.flatMap(taskRawStatus(in:))
                ?? resultTask.flatMap(taskRawStatus(in:))
            if rawStatus == "deleted" || rawStatus == "removed" {
                guard todos.contains(where: { $0.id == id }) else { return .ignored }
                todos.removeAll { $0.id == id }
                // Deleting the last task is a valid empty transition, not a
                // parse failure: the caller retires this workstream's rows.
                return .list(todos)
            }
            let state = input.flatMap(taskState(in:)) ?? resultTask.flatMap(taskState(in:))
            guard let index = todos.firstIndex(where: { $0.id == id }) else {
                // A task created before cmux was watching (resumed session, or
                // hooks installed mid-run). Adoptable only when the payload
                // describes it; claiming an id for a row we cannot render
                // would evict real ids from the bounded owned set.
                guard let content = resultTask.flatMap(taskContent(in:))
                    ?? input.flatMap(taskContent(in:)) else { return .ignored }
                claimId(id)
                upsert(WorkstreamTaskTodo(id: id, content: content, state: state ?? .pending))
                trimToCap()
                return .list(todos)
            }
            claimId(id)
            todos[index] = WorkstreamTaskTodo(
                id: id,
                // Subject only: a details-only update must not rewrite the
                // row's title with the new description.
                content: resultTask.flatMap(taskSubject(in:))
                    ?? input.flatMap(taskSubject(in:))
                    ?? todos[index].content,
                state: state ?? todos[index].state
            )
            return .list(todos)

        default:
            return .ignored
        }
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

    private mutating func trimToCap() {
        guard todos.count > Self.maxRetainedTodos else { return }
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

/// The task's display title. Deliberately excludes `description`: a
/// `TaskUpdate` may change only the task's details, and treating those as the
/// title would silently rewrite the checklist row's text.
private func taskSubject(in dict: [String: Any]) -> String? {
    for key in ["subject", "content", "title", "text"] {
        if let value = dict[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}

/// The best available text for a task being adopted for the first time, where
/// a description is better than dropping the row entirely.
private func taskContent(in dict: [String: Any]) -> String? {
    if let subject = taskSubject(in: dict) { return subject }
    if let value = dict["description"] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
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

/// Whether a whole-list entry names a task that is no longer outstanding work.
///
/// OpenCode's Todo schema permits `cancelled`. It is neither pending nor done,
/// and showing it as pending would overstate remaining work in the checklist
/// progress readout, so it is dropped from the snapshot instead.
private func isCancelledTask(_ dict: [String: Any]) -> Bool {
    switch taskRawStatus(in: dict) {
    case "cancelled", "canceled", "abandoned": return true
    default: return false
    }
}

/// A stable identity for a whole-list entry that carries no id of its own.
///
/// Derived from the entry's text rather than its position: OpenCode's
/// `todo.updated` payload has no ids, and keying on array index would let a
/// removal or reorder hand one task's identity — and the attachments and row
/// the checklist merge binds to it — to a different task. Two entries with
/// identical text still collapse, which is a far smaller error than
/// transplanting user data between tasks.
private func contentDerivedTaskId(_ content: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in content.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100_0000_01b3
    }
    return "content-\(String(hash, radix: 16))"
}

/// Parses the whole-list `TodoWrite` shape (`{"todos":[…]}` or a bare array).
///
/// - Returns: The parsed list, or `nil` when the payload carried no list at
///   all. An empty array parses to an empty list, which is a valid snapshot
///   meaning the agent cleared its plan.
func parseWorkstreamTodoWriteSnapshot(_ json: String?) -> [WorkstreamTaskTodo]? {
    guard let json, let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return nil }
    let raw: [Any]
    if let dict = root as? [String: Any] {
        guard let todos = dict["todos"] as? [Any] else { return nil }
        raw = todos
    } else if let array = root as? [Any] {
        raw = array
    } else {
        return nil
    }
    return raw.compactMap { element in
        guard let dict = element as? [String: Any],
              !isCancelledTask(dict),
              let content = taskContent(in: dict) else { return nil }
        return WorkstreamTaskTodo(
            id: taskId(in: dict) ?? contentDerivedTaskId(content),
            content: content,
            state: taskState(in: dict) ?? .pending
        )
    }
}
