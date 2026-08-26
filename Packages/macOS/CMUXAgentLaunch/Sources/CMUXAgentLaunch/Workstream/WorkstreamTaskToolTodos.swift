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
    private var completedRequestIDs: [String] = []
    private(set) var hasEvictedTodos = false
    private(set) var hasCompleteTaskList = false

    private static let maxPendingPreOperations = 64
    private var pendingPreOperations: [PendingPreOperation] = []
    private var pendingPostOperations: [PendingPostOperation] = []

    var isComplete: Bool {
        pendingPreOperations.isEmpty
            && pendingPostOperations.isEmpty
            && hasCompleteTaskList
            && !hasEvictedTodos
    }

    var ownedIds: Set<String> { projectedState().ownedIdSet }
    var ownedIDList: [String] { projectedState().ownedIDsInOrder }
    var isEmpty: Bool {
        let projected = projectedState()
        return projected.todos.isEmpty && projected.ownedIdSet.isEmpty
    }

    mutating func invalidateCompleteness() {
        hasCompleteTaskList = false
    }

    private func normalizedInput(_ inputJSON: String?) -> String? {
        guard let inputJSON, let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let normalized = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .fragmentsAllowed]
              ) else {
            return inputJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(data: normalized, encoding: .utf8)
    }

    private func responseIndicatesFailure(_ responseJSON: String?) -> Bool {
        object(from: responseJSON)?["success"] as? Bool == false
    }

    private mutating func appendPendingPost(_ operation: PendingPostOperation) {
        pendingPostOperations.append(operation)
        if pendingPostOperations.count > Self.maxPendingPreOperations {
            pendingPostOperations.removeFirst(
                pendingPostOperations.count - Self.maxPendingPreOperations
            )
        }
    }

    private mutating func rememberCompletedRequest(_ requestID: String?) {
        guard let requestID, !requestID.isEmpty,
              !completedRequestIDs.contains(requestID) else { return }
        completedRequestIDs.append(requestID)
        if completedRequestIDs.count > Self.maxOwnedIds {
            completedRequestIDs.removeFirst(completedRequestIDs.count - Self.maxOwnedIds)
        }
    }

    private func pendingOperationIndex(
        tool: WorkstreamTaskTool,
        inputJSON: String?,
        requestID: String?
    ) -> Int? {
        if let requestID, !requestID.isEmpty,
           let index = pendingPreOperations.firstIndex(where: {
                $0.tool == tool && $0.requestID == requestID
           }) {
            return index
        }
        let normalized = normalizedInput(inputJSON)
        let normalizedMatches = pendingPreOperations.indices.filter {
            pendingPreOperations[$0].tool == tool
                && normalizedInput(pendingPreOperations[$0].inputJSON) == normalized
        }
        if normalizedMatches.count == 1, let index = normalizedMatches.first {
            return index
        }
        let input = object(from: inputJSON)
        if let id = taskID(in: input) {
            let matches = pendingPreOperations.indices.filter {
                pendingPreOperations[$0].tool == tool
                    && taskID(in: object(from: pendingPreOperations[$0].inputJSON)) == id
            }
            if matches.count == 1, let index = matches.first { return index }
        }
        if let subject = content(in: input) {
            let matches = pendingPreOperations.indices.filter {
                pendingPreOperations[$0].tool == tool
                    && content(in: object(from: pendingPreOperations[$0].inputJSON)) == subject
            }
            if matches.count == 1, let index = matches.first { return index }
            if tool == .taskCreate, let first = matches.first { return first }
        }
        return nil
    }

    private func pendingPostIndex(
        tool: WorkstreamTaskTool,
        inputJSON: String?,
        requestID: String?
    ) -> Int? {
        if let requestID, !requestID.isEmpty,
           let index = pendingPostOperations.firstIndex(where: {
                $0.tool == tool && $0.requestID == requestID
           }) {
            return index
        }
        let normalized = normalizedInput(inputJSON)
        let normalizedMatches = pendingPostOperations.indices.filter {
            pendingPostOperations[$0].tool == tool
                && normalizedInput(pendingPostOperations[$0].inputJSON) == normalized
        }
        if normalizedMatches.count == 1, let index = normalizedMatches.first {
            return index
        }
        let input = object(from: inputJSON)
        if let id = taskID(in: input) {
            let matches = pendingPostOperations.indices.filter {
                pendingPostOperations[$0].tool == tool
                    && taskID(in: object(from: pendingPostOperations[$0].inputJSON)) == id
            }
            if matches.count == 1, let index = matches.first { return index }
        }
        if let subject = content(in: input) {
            let matches = pendingPostOperations.indices.filter {
                pendingPostOperations[$0].tool == tool
                    && content(in: object(from: pendingPostOperations[$0].inputJSON)) == subject
            }
            if matches.count == 1, let index = matches.first { return index }
            if tool == .taskCreate, let first = matches.first { return first }
        }
        return nil
    }

    private func projectedState() -> WorkstreamTaskToolTodos {
        guard !pendingPreOperations.isEmpty else { return self }
        var projected = self
        let operations = pendingPreOperations
        projected.pendingPreOperations.removeAll(keepingCapacity: true)
        projected.pendingPostOperations.removeAll(keepingCapacity: true)
        for operation in operations {
            if case .failure = operation.completion { continue }
            let preOutcome = projected.applyPreMutation(
                tool: operation.tool,
                inputJSON: operation.inputJSON,
                requestID: operation.requestID,
                establishesCompleteness: false,
                assignedProvisionalID: operation.assignedProvisionalID
            )
            if case .success(let responseJSON) = operation.completion,
               preOutcome.producedList {
                _ = projected.applyPostMutation(
                    tool: operation.tool,
                    inputJSON: operation.inputJSON,
                    responseJSON: responseJSON,
                    isError: false
                )
            }
        }
        return projected
    }

    private mutating func adoptCommittedState(from candidate: WorkstreamTaskToolTodos) {
        todos = candidate.todos
        ownedIDsInOrder = candidate.ownedIDsInOrder
        ownedIdSet = candidate.ownedIdSet
        provisionalIDsBySubject = candidate.provisionalIDsBySubject
        provisionalIDsInOrder = candidate.provisionalIDsInOrder
        nextProvisionalID = candidate.nextProvisionalID
        hasEvictedTodos = candidate.hasEvictedTodos
        hasCompleteTaskList = candidate.hasCompleteTaskList
    }

    private mutating func reconcileReadyOperations() {
        while let completion = pendingPreOperations.first?.completion {
            let operation = pendingPreOperations.removeFirst()
            switch completion {
            case .failure:
                break
            case .success(let responseJSON):
                var candidate = self
                let preOutcome = candidate.applyPreMutation(
                    tool: operation.tool,
                    inputJSON: operation.inputJSON,
                    requestID: operation.requestID,
                    establishesCompleteness: false,
                    assignedProvisionalID: operation.assignedProvisionalID
                )
                let postOutcome = preOutcome.producedList
                    ? candidate.applyPostMutation(
                        tool: operation.tool,
                        inputJSON: operation.inputJSON,
                        responseJSON: responseJSON,
                        isError: false
                    )
                    : .ignored
                if postOutcome.producedList {
                    adoptCommittedState(from: candidate)
                } else {
                    hasCompleteTaskList = false
                }
            }
            rememberCompletedRequest(operation.requestID)
        }
    }

    /// Seeds the accumulator from persisted agent rows after an app restart.
    mutating func seed(with restored: [WorkstreamTaskTodo]) {
        pendingPreOperations.removeAll(keepingCapacity: true)
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
        if let requestID, completedRequestIDs.contains(requestID) {
            return .ignored
        }
        if establishesCompleteness {
            pendingPreOperations.removeAll(keepingCapacity: true)
            pendingPostOperations.removeAll(keepingCapacity: true)
            return applyPreMutation(
                tool: tool,
                inputJSON: inputJSON,
                requestID: requestID,
                establishesCompleteness: true,
                assignedProvisionalID: nil
            )
        }
        var projected = projectedState()
        let assignedProvisionalID = projected.preallocatedProvisionalID(tool: tool, inputJSON: inputJSON)
        let outcome = projected.applyPreMutation(
            tool: tool,
            inputJSON: inputJSON,
            requestID: requestID,
            establishesCompleteness: false,
            assignedProvisionalID: assignedProvisionalID
        )
        guard outcome.producedList else { return outcome }
        hasCompleteTaskList = false
        var operation = PendingPreOperation(
            tool: tool,
            inputJSON: inputJSON,
            requestID: requestID,
            assignedProvisionalID: assignedProvisionalID,
            completion: nil
        )
        if let pendingPostIndex = pendingPostIndex(
            tool: tool,
            inputJSON: inputJSON,
            requestID: requestID
        ) {
            let pendingPost = pendingPostOperations.remove(at: pendingPostIndex)
            operation.completion = pendingPost.isError
                ? .failure
                : .success(responseJSON: pendingPost.responseJSON)
        }
        pendingPreOperations.append(operation)
        reconcileReadyOperations()
        if pendingPreOperations.count > Self.maxPendingPreOperations {
            pendingPreOperations.removeFirst(pendingPreOperations.count - Self.maxPendingPreOperations)
            hasCompleteTaskList = false
        }
        return .list(projectedState().todos)
    }

    private mutating func applyPreMutation(
        tool: WorkstreamTaskTool,
        inputJSON: String?,
        requestID: String?,
        establishesCompleteness: Bool,
        assignedProvisionalID: String?
    ) -> WorkstreamTaskToolOutcome {
        let input = object(from: inputJSON)
        switch tool {
        case .todoWrite:
            guard let parsed = Self.snapshot(from: inputJSON) else { return .ignored }
            replace(with: parsed, establishesCompleteness: establishesCompleteness)
            return .list(todos)
        case .taskCreate:
            guard let content = content(in: input) else { return .ignored }
            let id: String
            if let explicitID = taskID(in: input) {
                id = explicitID
            } else if let assignedProvisionalID {
                registerProvisionalID(assignedProvisionalID, for: content)
                id = assignedProvisionalID
            } else {
                id = provisionalID(for: content)
            }
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

    /// Applies a completed task-tool event and reconciles its pending pre-tool operation.
    mutating func applyPost(
        tool: WorkstreamTaskTool,
        inputJSON: String?,
        responseJSON: String?,
        isError: Bool,
        requestID: String? = nil
    ) -> WorkstreamTaskToolOutcome {
        let completion: PendingCompletion = isError || responseIndicatesFailure(responseJSON)
            ? .failure
            : .success(responseJSON: responseJSON)

        // Claude can emit a response-less PostToolUse frame for a task create
        // on older wrappers. Keep the provisional row in the projected state
        // until an authoritative id arrives instead of treating the missing
        // response as a successful create.
        if tool == .taskCreate, responseJSON == nil, !isError {
            hasCompleteTaskList = false
            return .list(projectedState().todos)
        }

        if tool == .todoWrite || tool == .taskList,
           case .success(let authoritativeResponse) = completion {
            pendingPreOperations.removeAll(keepingCapacity: true)
            pendingPostOperations.removeAll(keepingCapacity: true)
            let outcome = applyPostMutation(
                tool: tool,
                inputJSON: inputJSON,
                responseJSON: authoritativeResponse,
                isError: false
            )
            guard outcome.producedList else {
                hasCompleteTaskList = false
                return .ignored
            }
            completedRequestIDs.removeAll(keepingCapacity: true)
            return .list(todos)
        }

        if let pendingIndex = pendingOperationIndex(
            tool: tool,
            inputJSON: inputJSON,
            requestID: requestID
        ) {
            pendingPreOperations[pendingIndex].completion = completion
            reconcileReadyOperations()
            return .list(projectedState().todos)
        }
        if pendingPostIndex(
            tool: tool,
            inputJSON: inputJSON,
            requestID: requestID
        ) != nil {
            return .list(projectedState().todos)
        }

        switch completion {
        case .failure:
            appendPendingPost(PendingPostOperation(
                tool: tool,
                inputJSON: inputJSON,
                responseJSON: responseJSON,
                isError: true,
                requestID: requestID
            ))
            hasCompleteTaskList = false
            return .list(projectedState().todos)
        case .success(let responseJSON):
            let outcome = applyPostMutation(
                tool: tool,
                inputJSON: inputJSON,
                responseJSON: responseJSON,
                isError: false
            )
            guard outcome.producedList else {
                appendPendingPost(PendingPostOperation(
                    tool: tool,
                    inputJSON: inputJSON,
                    responseJSON: responseJSON,
                    isError: false,
                    requestID: requestID
                ))
                hasCompleteTaskList = false
                return .list(projectedState().todos)
            }
            rememberCompletedRequest(requestID)
            hasCompleteTaskList = false
            return .list(projectedState().todos)
        }
    }

    private mutating func applyPostMutation(
        tool: WorkstreamTaskTool,
        inputJSON: String?,
        responseJSON: String?,
        isError: Bool
    ) -> WorkstreamTaskToolOutcome {
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
            let inputID = taskID(in: input)
            let resultID = taskID(in: result)
            guard inputID == nil || resultID == nil || inputID == resultID,
                  let authoritativeID = resultID,
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
            let inputID = taskID(in: input)
            let resultID = taskID(in: result)
            guard inputID == nil || resultID == nil || inputID == resultID,
                  let id = inputID ?? resultID else { return .ignored }
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

    private func preallocatedProvisionalID(
        tool: WorkstreamTaskTool,
        inputJSON: String?
    ) -> String? {
        guard tool == .taskCreate,
              let input = object(from: inputJSON),
              taskID(in: input) == nil,
              content(in: input) != nil else { return nil }
        return "pending-" + String(nextProvisionalID + 1)
    }

    private mutating func registerProvisionalID(_ id: String, for subject: String) {
        if !provisionalIDsBySubject[subject, default: []].contains(id) {
            provisionalIDsBySubject[subject, default: []].append(id)
        }
        if !provisionalIDsInOrder.contains(id) {
            provisionalIDsInOrder.append(id)
        }
        if id.hasPrefix("pending-"),
           let suffix = Int(id.dropFirst("pending-".count)) {
            nextProvisionalID = max(nextProvisionalID, suffix)
        }
    }

    private mutating func provisionalID(for subject: String) -> String {
        nextProvisionalID += 1
        let id = "pending-" + String(nextProvisionalID)
        registerProvisionalID(id, for: subject)
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
