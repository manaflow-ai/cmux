import Foundation

/// Accumulates the delta-shaped task calls emitted by Claude Code.
///
/// `TodoWrite` reports a complete list. `TaskCreate` and `TaskUpdate` report
/// one mutation at a time, and a create's authoritative id may exist only in
/// the completed tool response. The accumulator accepts both pre- and
/// post-tool events so older wrappers continue to work while newer wrappers
/// can reconcile provisional ids with the result returned by Claude.
struct WorkstreamTaskToolTodos: Sendable {
    /// Matches the per-workspace checklist cap.
    static let maxRetainedTodos = 50
    /// Bounds ownership metadata retained for deleted/evicted tasks.
    static let maxOwnedIds = 200

    private var todos: [WorkstreamTaskTodo] = []
    private var ownedIDsInOrder: [String] = []
    private var ownedIdSet: Set<String> = []
    private var provisionalIDsBySubject: [String: [String]] = [:]
    private var provisionalIDsInOrder: [String] = []
    private var nextProvisionalID = 0
    private var completedCreateRequestIDs: [String] = []
    private(set) var hasEvictedTodos = false
    private(set) var hasCompleteTaskList = false

    var isComplete: Bool { hasCompleteTaskList && !hasEvictedTodos }

    var ownedIds: Set<String> { ownedIdSet }
    var ownedIDList: [String] { ownedIDsInOrder }
    var isEmpty: Bool { todos.isEmpty && ownedIdSet.isEmpty }

    mutating func invalidateCompleteness() {
        hasCompleteTaskList = false
    }

    /// Seeds the accumulator from persisted agent rows after an app restart.
    mutating func seed(with restored: [WorkstreamTaskTodo]) {
        todos = restored
        hasEvictedTodos = true
        hasCompleteTaskList = false
        for todo in restored {
            claim(todo.id)
            if todo.id.hasPrefix("pending-"),
               let suffix = Int(todo.id.dropFirst("pending-".count)) {
                nextProvisionalID = max(nextProvisionalID, suffix)
                provisionalIDsInOrder.append(todo.id)
            }
        }
        trim()
    }

    /// Applies a pre-execution event. This keeps compatibility with wrappers
    /// that only forward `PreToolUse`; a later completed event can reconcile a
    /// provisional create or roll back a failed call.
    mutating func applyPre(
        tool: WorkstreamTaskTool,
        inputJSON: String?,
        requestID: String? = nil,
        establishesCompleteness: Bool = false
    ) -> WorkstreamTaskToolOutcome {
        if tool == .taskCreate,
           let requestID,
           completedCreateRequestIDs.contains(requestID) {
            return .ignored
        }
        hasCompleteTaskList = false
        let input = object(from: inputJSON)
        switch tool {
        case .todoWrite:
            guard let parsed = Self.snapshot(from: inputJSON) else { return .ignored }
            replace(with: parsed, establishesCompleteness: establishesCompleteness)
            return .list(todos)
        case .taskCreate:
            guard let content = content(in: input) else { return .ignored }
            let id = taskID(in: input) ?? provisionalID(for: content)
            claim(id)
            upsert(WorkstreamTaskTodo(id: id, content: content, state: state(in: input) ?? .pending))
            trim()
            return .list(todos)
        case .taskUpdate:
            guard let id = taskID(in: input) else { return .ignored }
            return applyUpdate(id: id, input: input, response: nil)
        case .taskGet:
            return .ignored
        case .taskList:
            guard let parsed = Self.snapshot(from: inputJSON) else { return .ignored }
            replace(with: parsed, establishesCompleteness: establishesCompleteness)
            return .list(todos)
        }
    }

    /// Applies a completed task-tool event and ignores failed tool calls.
    mutating func applyPost(
        tool: WorkstreamTaskTool,
        inputJSON: String?,
        responseJSON: String?,
        isError: Bool,
        requestID: String? = nil
    ) -> WorkstreamTaskToolOutcome {
        if tool == .taskCreate, let requestID {
            rememberCompletedCreateRequest(requestID)
        }
        let input = object(from: inputJSON)
        let response = object(from: responseJSON)
        let result = (response?["task"] as? [String: Any]) ?? response
        if isError || response?["success"] as? Bool == false {
            if tool == .taskCreate,
               let subject = content(in: input),
               let provisional = popProvisionalID(for: subject) {
                todos.removeAll { $0.id == provisional }
                unclaim(provisional)
                provisionalIDsInOrder.removeAll { $0 == provisional }
                return .list(todos)
            }
            return .ignored
        }

        switch tool {
        case .todoWrite:
            guard let parsed = Self.snapshot(from: inputJSON) else { return .ignored }
            replace(with: parsed, establishesCompleteness: true)
            return .list(todos)
        case .taskCreate:
            guard let authoritativeID = taskID(in: result),
                  let subject = content(in: result) ?? content(in: input) else { return .ignored }
            let provisional = popProvisionalID(for: subject)
            if let provisional, provisional != authoritativeID {
                todos.removeAll { $0.id == provisional }
            }
            claim(authoritativeID)
            upsert(WorkstreamTaskTodo(
                id: authoritativeID,
                content: subject,
                state: state(in: result) ?? state(in: input) ?? .pending
            ))
            trim()
            return .list(todos)
        case .taskUpdate:
            guard let id = taskID(in: input) ?? taskID(in: result) else { return .ignored }
            return applyUpdate(id: id, input: input, response: result)
        case .taskGet:
            let rawStatus = result.flatMap { $0["status"] as? String }
            guard let result,
                  let requestedID = taskID(in: input),
                  let resultID = taskID(in: result),
                  requestedID == resultID,
                  state(in: result) != nil
                    || content(in: result) != nil
                    || rawStatus == "deleted"
                    || rawStatus == "removed" else {
                hasCompleteTaskList = false
                return .ignored
            }
            return applyUpdate(id: resultID, input: input, response: result)
        case .taskList:
            let snapshotJSON = responseJSON ?? inputJSON
            guard let parsed = Self.snapshot(from: snapshotJSON) else { return .ignored }
            replace(with: parsed, establishesCompleteness: true)
            return .list(todos)
        }
    }

    private mutating func applyUpdate(
        id: String,
        input: [String: Any]?,
        response: [String: Any]?
    ) -> WorkstreamTaskToolOutcome {
        let resolvedID = adoptProvisionalIDIfNeeded(id)
        let rawStatus = (input?["status"] as? String) ?? (input?["state"] as? String)
            ?? (response?["status"] as? String) ?? (response?["state"] as? String)
        if rawStatus == "deleted" || rawStatus == "removed" {
            guard todos.contains(where: { $0.id == resolvedID }) else {
                hasCompleteTaskList = false
                return .ignored
            }
            todos.removeAll { $0.id == resolvedID }
            claim(resolvedID)
            return .list(todos)
        }

        let nextState = state(in: input) ?? state(in: response)
        if let index = todos.firstIndex(where: { $0.id == resolvedID }) {
            claim(resolvedID)
            let title = subject(in: response) ?? subject(in: input) ?? todos[index].content
            todos[index] = WorkstreamTaskTodo(id: resolvedID, content: title, state: nextState ?? todos[index].state)
            return .list(todos)
        }

        // Older Claude wrappers expose only PreToolUse. Claude assigns task
        // ids in creation order, so reconcile a numeric TaskUpdate id with
        // the corresponding provisional row rather than dropping the delta.
        if let ordinal = Int(id), ordinal > 0,
           provisionalIDsInOrder.indices.contains(ordinal - 1) {
            let provisional = provisionalIDsInOrder[ordinal - 1]
            if let provisionalIndex = todos.firstIndex(where: { $0.id == provisional }) {
                let title = subject(in: response) ?? subject(in: input) ?? todos[provisionalIndex].content
                let updated = WorkstreamTaskTodo(
                    id: id,
                    content: title,
                    state: nextState ?? todos[provisionalIndex].state
                )
                todos[provisionalIndex] = updated
                provisionalIDsInOrder[ordinal - 1] = id
                replaceProvisionalReference(from: provisional, to: id)
                claim(id)
                return .list(todos)
            }
        }

        // A resumed session can send an update before cmux saw its create. Do
        // not claim an id unless the payload also gives us display text.
        guard let title = content(in: response) ?? content(in: input) else {
            hasCompleteTaskList = false
            return .ignored
        }
        hasCompleteTaskList = false
        claim(resolvedID)
        upsert(WorkstreamTaskTodo(id: resolvedID, content: title, state: nextState ?? .pending))
        trim()
        return .list(todos)
    }

    private mutating func replace(
        with parsed: [WorkstreamTaskTodo],
        establishesCompleteness: Bool
    ) {
        todos = parsed
        hasCompleteTaskList = establishesCompleteness
        hasEvictedTodos = false
        for todo in parsed { claim(todo.id) }
        trim()
    }

    private mutating func upsert(_ todo: WorkstreamTaskTodo) {
        if let index = todos.firstIndex(where: { $0.id == todo.id }) {
            todos[index] = todo
        } else {
            todos.append(todo)
        }
    }

    private mutating func claim(_ id: String) {
        guard ownedIdSet.insert(id).inserted else { return }
        ownedIDsInOrder.append(id)
        guard ownedIDsInOrder.count > Self.maxOwnedIds else { return }
        let overflow = ownedIDsInOrder.count - Self.maxOwnedIds
        for old in ownedIDsInOrder.prefix(overflow) { ownedIdSet.remove(old) }
        ownedIDsInOrder.removeFirst(overflow)
    }

    private mutating func trim() {
        if todos.count > Self.maxRetainedTodos {
            hasEvictedTodos = true
            todos.removeFirst(todos.count - Self.maxRetainedTodos)
        }
        let activeIDs = Set(todos.map(\.id))
        provisionalIDsInOrder.removeAll { !activeIDs.contains($0) }
        for subject in Array(provisionalIDsBySubject.keys) {
            let retained = provisionalIDsBySubject[subject, default: []].filter(activeIDs.contains)
            if retained.isEmpty {
                provisionalIDsBySubject.removeValue(forKey: subject)
            } else {
                provisionalIDsBySubject[subject] = retained
            }
        }
    }

    private mutating func rememberCompletedCreateRequest(_ requestID: String) {
        guard !completedCreateRequestIDs.contains(requestID) else { return }
        completedCreateRequestIDs.append(requestID)
        if completedCreateRequestIDs.count > Self.maxOwnedIds {
            completedCreateRequestIDs.removeFirst(completedCreateRequestIDs.count - Self.maxOwnedIds)
        }
    }

    private mutating func provisionalID(for subject: String) -> String {
        nextProvisionalID += 1
        let id = "pending-" + String(nextProvisionalID)
        provisionalIDsBySubject[subject, default: []].append(id)
        provisionalIDsInOrder.append(id)
        return id
    }

    private mutating func popProvisionalID(for subject: String) -> String? {
        guard var ids = provisionalIDsBySubject[subject], !ids.isEmpty else { return nil }
        let id = ids.removeFirst()
        if ids.isEmpty {
            provisionalIDsBySubject.removeValue(forKey: subject)
        } else {
            provisionalIDsBySubject[subject] = ids
        }
        provisionalIDsInOrder.removeAll { $0 == id }
        return id
    }

    private mutating func replaceProvisionalReference(from oldID: String, to newID: String) {
        for subject in Array(provisionalIDsBySubject.keys) {
            guard var ids = provisionalIDsBySubject[subject],
                  let index = ids.firstIndex(of: oldID) else { continue }
            ids[index] = newID
            provisionalIDsBySubject[subject] = ids
            return
        }
    }

    private mutating func unclaim(_ id: String) {
        ownedIdSet.remove(id)
        ownedIDsInOrder.removeAll { $0 == id }
    }

    private mutating func adoptProvisionalIDIfNeeded(_ id: String) -> String {
        guard todos.contains(where: { $0.id == id }) == false,
              let ordinal = Int(id), ordinal > 0,
              provisionalIDsInOrder.indices.contains(ordinal - 1) else {
            return id
        }
        let provisional = provisionalIDsInOrder[ordinal - 1]
        guard let index = todos.firstIndex(where: { $0.id == provisional }) else { return id }
        let current = todos[index]
        todos[index] = WorkstreamTaskTodo(id: id, content: current.content, state: current.state)
        provisionalIDsInOrder[ordinal - 1] = id
        replaceProvisionalReference(from: provisional, to: id)
        claim(id)
        return id
    }

    private static func object(from json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
    }

    private func object(from json: String?) -> [String: Any]? { Self.object(from: json) }

    private static func taskID(in object: [String: Any]?) -> String? {
        guard let object else { return nil }
        for key in ["taskId", "task_id", "id"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? Int { return String(value) }
        }
        return nil
    }

    private func taskID(in object: [String: Any]?) -> String? { Self.taskID(in: object) }

    private static func subject(in object: [String: Any]?) -> String? {
        guard let object else { return nil }
        for key in ["subject", "content", "title", "text"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func subject(in object: [String: Any]?) -> String? { Self.subject(in: object) }

    private static func content(in object: [String: Any]?) -> String? {
        subject(in: object) ?? (object?["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func content(in object: [String: Any]?) -> String? { Self.content(in: object) }

    private static func state(in object: [String: Any]?) -> WorkstreamTaskTodo.State? {
        guard let raw = (object?["status"] as? String) ?? (object?["state"] as? String) else { return nil }
        switch raw {
        case "completed", "done": return .completed
        case "inProgress", "in_progress", "active": return .inProgress
        case "pending", "todo", "open": return .pending
        default: return nil
        }
    }

    private func state(in object: [String: Any]?) -> WorkstreamTaskTodo.State? { Self.state(in: object) }

    private static func snapshot(from json: String?) -> [WorkstreamTaskTodo]? {
        guard let json, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let values: [Any]
        if let dictionary = root as? [String: Any] {
            guard let todos = (dictionary["todos"] as? [Any])
                ?? (dictionary["tasks"] as? [Any])
                ?? (dictionary["task"] as? [String: Any]).map({ [$0] }) else { return nil }
            values = todos
        } else if let array = root as? [Any] {
            values = array
        } else {
            return nil
        }
        var occurrences: [String: Int] = [:]
        var parsed: [WorkstreamTaskTodo] = []
        parsed.reserveCapacity(values.count)
        for value in values {
            guard let dictionary = value as? [String: Any],
                  let text = content(in: dictionary) else { return nil }
            let base = taskID(in: dictionary) ?? ("content-" + text)
            let count = (occurrences[base] ?? 0) + 1
            occurrences[base] = count
            let id = count == 1 ? base : base + "-" + String(count)
            parsed.append(WorkstreamTaskTodo(id: id, content: text, state: state(in: dictionary) ?? .pending))
        }
        return parsed
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
