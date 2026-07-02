internal import Foundation

/// The workspace-todo domain (`workspace.status.*` + `workspace.todo.*`):
/// per-workspace todo lifecycle status (inferred from live signals with an
/// optional manual override) and the persisted checklist. New in this domain
/// (no legacy `v2` bodies); payload shapes follow the `workspace.*` /
/// `workspace.group.*` conventions.
extension ControlCommandCoordinator {
    /// Dispatches the workspace-todo methods this coordinator owns; returns
    /// `nil` for anything else so the core `handle(_:)` can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a workspace-todo method.
    func handleWorkspaceTodo(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "workspace.status.get":
            return workspaceStatusGet(request.params)
        case "workspace.status.set":
            return workspaceStatusSet(request.params)
        case "workspace.todo.list":
            return workspaceTodoList(request.params)
        case "workspace.todo.add":
            return workspaceTodoAdd(request.params)
        case "workspace.todo.set_state":
            return workspaceTodoSetState(request.params)
        case "workspace.todo.remove":
            return workspaceTodoRemove(request.params)
        case "workspace.todo.clear":
            return workspaceTodoClear(request.params)
        default:
            return nil
        }
    }

    // MARK: - Payloads

    /// Builds the status payload: effective/inferred lanes, the override (or
    /// JSON `null` for automatic), and the signals behind the inference.
    private func workspaceTodoStatusPayload(
        windowID: UUID?,
        status: ControlWorkspaceTodoStatusSnapshot
    ) -> JSONValue {
        let overridePayload: JSONValue
        if let overrideStatus = status.overrideStatus,
           let overrideInferredAt = status.overrideInferredAt {
            overridePayload = .object([
                "status": .string(overrideStatus),
                "inferred_at_override": .string(overrideInferredAt),
            ])
        } else {
            overridePayload = .null
        }
        return .object([
            "workspace_id": .string(status.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, status.workspaceID),
            "window_id": orNull(windowID?.uuidString),
            "window_ref": ref(.window, windowID),
            "effective": .string(status.effective),
            "inferred": .string(status.inferred),
            "override": overridePayload,
            "signals": .object([
                "any_agent_needs_input": .bool(status.signals.anyAgentNeedsInput),
                "any_agent_running": .bool(status.signals.anyAgentRunning),
                "any_open_pull_request": .bool(status.signals.anyOpenPullRequest),
                "has_pull_requests": .bool(status.signals.hasPullRequests),
                "all_pull_requests_merged_or_closed": .bool(status.signals.allPullRequestsMergedOrClosed),
                "is_git_dirty": .bool(status.signals.isGitDirty),
            ]),
        ])
    }

    /// Builds one checklist item row (with its current 0-based index).
    private func workspaceTodoItemPayload(
        _ item: ControlWorkspaceTodoChecklistSnapshot.Item,
        index: Int?
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(item.id.uuidString),
            "text": .string(item.text),
            "state": .string(item.state),
            "origin": .string(item.origin),
        ]
        if let index {
            object["index"] = .int(Int64(index))
        }
        return .object(object)
    }

    /// Builds the checklist progress payload.
    private func workspaceTodoProgressPayload(
        _ checklist: ControlWorkspaceTodoChecklistSnapshot
    ) -> JSONValue {
        .object([
            "completed": .int(Int64(checklist.completedCount)),
            "total": .int(Int64(checklist.items.count)),
            "first_unchecked_text": orNull(checklist.firstUncheckedText),
        ])
    }

    /// Builds the shared mutation-success payload: workspace/window identity,
    /// the touched item (when one exists), and the post-mutation progress.
    private func workspaceTodoMutationPayload(
        windowID: UUID?,
        item: ControlWorkspaceTodoChecklistSnapshot.Item?,
        removedCount: Int?,
        checklist: ControlWorkspaceTodoChecklistSnapshot
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "workspace_id": .string(checklist.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, checklist.workspaceID),
            "window_id": orNull(windowID?.uuidString),
            "window_ref": ref(.window, windowID),
            "progress": workspaceTodoProgressPayload(checklist),
        ]
        if let item {
            let index = checklist.items.firstIndex(where: { $0.id == item.id })
            object["item"] = workspaceTodoItemPayload(item, index: index)
        }
        if let removedCount {
            object["removed_count"] = .int(Int64(removedCount))
        }
        return .object(object)
    }

    // MARK: - Shared error shaping

    /// Maps the shared mutation failure cases; `nil` means the resolution was
    /// a success and the caller shapes it.
    private func workspaceTodoMutationError(
        _ resolution: ControlWorkspaceTodoMutationResolution
    ) -> ControlCallResult? {
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .itemNotFound:
            return .err(code: "not_found", message: "Checklist item not found", data: nil)
        case .emptyText:
            return .err(code: "invalid_params", message: "text must not be empty", data: nil)
        case .checklistFull:
            return .err(code: "invalid_state", message: "Checklist is full", data: nil)
        case .invalidState(let raw):
            return .err(
                code: "invalid_params",
                message: "state must be one of: pending, in-progress, completed",
                data: .object(["state": .string(raw)])
            )
        case .invalidOrigin(let raw):
            return .err(
                code: "invalid_params",
                message: "origin must be one of: user, agent",
                data: .object(["origin": .string(raw)])
            )
        case .resolved:
            return nil
        }
    }

    /// Shapes a status resolution into the shared status payload.
    private func workspaceTodoStatusResult(
        _ resolution: ControlWorkspaceTodoStatusResolution
    ) -> ControlCallResult {
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .invalidStatus(let raw):
            return .err(
                code: "invalid_params",
                message: "status must be one of: todo, working, needs-attention, review, done, auto",
                data: .object(["status": .string(raw)])
            )
        case .resolved(let windowID, let status):
            return .ok(workspaceTodoStatusPayload(windowID: windowID, status: status))
        }
    }

    /// The item id/index selector pair: (`id` UUID-or-ref param, 0-based
    /// `index` param). `nil` when neither is present.
    private func workspaceTodoItemSelector(
        _ params: [String: JSONValue]
    ) -> (itemID: UUID?, itemIndex: Int?)? {
        let itemID = uuid(params, "id")
        let itemIndex = int(params, "index")
        guard itemID != nil || itemIndex != nil else { return nil }
        return (itemID, itemIndex)
    }

    // MARK: - Status

    /// `workspace.status.get` — the workspace's effective/inferred todo status.
    func workspaceStatusGet(_ params: [String: JSONValue]) -> ControlCallResult {
        workspaceTodoStatusResult(
            context?.controlWorkspaceTaskStatus(
                routing: routingSelectors(params),
                workspaceID: uuid(params, "workspace_id")
            ) ?? .tabManagerUnavailable
        )
    }

    /// `workspace.status.set` — pin a manual status lane, or `auto` to clear.
    func workspaceStatusSet(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let raw = string(params, "status") else {
            return .err(code: "invalid_params", message: "Missing or invalid status", data: nil)
        }
        // "auto" clears the override; any other value crosses the seam raw and
        // the app validates it against the status lanes.
        let statusRaw: String? = raw.lowercased() == "auto" ? nil : raw
        return workspaceTodoStatusResult(
            context?.controlSetWorkspaceTaskStatus(
                routing: routingSelectors(params),
                workspaceID: uuid(params, "workspace_id"),
                statusRaw: statusRaw
            ) ?? .tabManagerUnavailable
        )
    }

    // MARK: - Checklist

    /// `workspace.todo.list` — the checklist items + progress.
    func workspaceTodoList(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlWorkspaceTodoList(
            routing: routingSelectors(params),
            workspaceID: uuid(params, "workspace_id")
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .resolved(let windowID, let checklist):
            return .ok(.object([
                "workspace_id": .string(checklist.workspaceID.uuidString),
                "workspace_ref": ref(.workspace, checklist.workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "items": .array(checklist.items.enumerated().map { index, item in
                    workspaceTodoItemPayload(item, index: index)
                }),
                "progress": workspaceTodoProgressPayload(checklist),
            ]))
        }
    }

    /// `workspace.todo.add` — append a checklist item.
    func workspaceTodoAdd(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let text = rawString(params, "text") else {
            return .err(code: "invalid_params", message: "Missing or invalid text", data: nil)
        }
        let resolution = context?.controlWorkspaceTodoAdd(
            routing: routingSelectors(params),
            workspaceID: uuid(params, "workspace_id"),
            text: text,
            stateRaw: string(params, "state"),
            originRaw: string(params, "origin")
        ) ?? .tabManagerUnavailable
        if let error = workspaceTodoMutationError(resolution) { return error }
        guard case .resolved(let windowID, let item, _, let checklist) = resolution else {
            return .err(code: "internal", message: "Unexpected resolution", data: nil)
        }
        return .ok(workspaceTodoMutationPayload(
            windowID: windowID, item: item, removedCount: nil, checklist: checklist
        ))
    }

    /// `workspace.todo.set_state` — set one item's state by id or index.
    func workspaceTodoSetState(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let selector = workspaceTodoItemSelector(params) else {
            return .err(code: "invalid_params", message: "Missing id or index", data: nil)
        }
        guard let stateRaw = string(params, "state") else {
            return .err(code: "invalid_params", message: "Missing or invalid state", data: nil)
        }
        let resolution = context?.controlWorkspaceTodoSetState(
            routing: routingSelectors(params),
            workspaceID: uuid(params, "workspace_id"),
            itemID: selector.itemID,
            itemIndex: selector.itemIndex,
            stateRaw: stateRaw
        ) ?? .tabManagerUnavailable
        if let error = workspaceTodoMutationError(resolution) { return error }
        guard case .resolved(let windowID, let item, _, let checklist) = resolution else {
            return .err(code: "internal", message: "Unexpected resolution", data: nil)
        }
        return .ok(workspaceTodoMutationPayload(
            windowID: windowID, item: item, removedCount: nil, checklist: checklist
        ))
    }

    /// `workspace.todo.remove` — remove one item by id or index.
    func workspaceTodoRemove(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let selector = workspaceTodoItemSelector(params) else {
            return .err(code: "invalid_params", message: "Missing id or index", data: nil)
        }
        let resolution = context?.controlWorkspaceTodoRemove(
            routing: routingSelectors(params),
            workspaceID: uuid(params, "workspace_id"),
            itemID: selector.itemID,
            itemIndex: selector.itemIndex
        ) ?? .tabManagerUnavailable
        if let error = workspaceTodoMutationError(resolution) { return error }
        guard case .resolved(let windowID, let item, let removedCount, let checklist) = resolution else {
            return .err(code: "internal", message: "Unexpected resolution", data: nil)
        }
        return .ok(workspaceTodoMutationPayload(
            windowID: windowID, item: item, removedCount: removedCount, checklist: checklist
        ))
    }

    /// `workspace.todo.clear` — remove every item.
    func workspaceTodoClear(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlWorkspaceTodoClear(
            routing: routingSelectors(params),
            workspaceID: uuid(params, "workspace_id")
        ) ?? .tabManagerUnavailable
        if let error = workspaceTodoMutationError(resolution) { return error }
        guard case .resolved(let windowID, _, let removedCount, let checklist) = resolution else {
            return .err(code: "internal", message: "Unexpected resolution", data: nil)
        }
        return .ok(workspaceTodoMutationPayload(
            windowID: windowID, item: nil, removedCount: removedCount, checklist: checklist
        ))
    }
}
