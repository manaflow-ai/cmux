internal import Foundation

/// Cross-workspace queue verbs. The app seam supplies snapshots and performs
/// dispatch; this coordinator only validates selectors and shapes wire data.
extension ControlCommandCoordinator {
    func handleWorkspaceTaskQueue(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "workspace.todo.queue.list", "workspace.todo.queue.refresh",
             "todo.queue.list", "todo.queue.refresh":
            return workspaceTaskQueueList(request.params)
        case "workspace.todo.queue.dispatch", "todo.queue.dispatch":
            return workspaceTaskQueueDispatch(request.params)
        case "workspace.todo.queue.reveal", "todo.queue.reveal":
            return workspaceTaskQueueReveal(request.params)
        case "workspace.todo.queue.target", "todo.queue.target":
            return workspaceTaskQueueSetTarget(request.params)
        default:
            return nil
        }
    }

    private func queueItemPayload(_ item: ControlWorkspaceTaskQueueItem) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(item.id.uuidString),
            "text": .string(item.text),
            "state": .string(item.state),
            "workspace_id": .string(item.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, item.workspaceID),
            "workspace_title": .string(item.workspaceTitle),
            "window_id": orNull(item.windowID?.uuidString),
            "window_ref": ref(.window, item.windowID),
            "owning_agent": orNull(item.owningAgent),
            "last_activity_at": orNull(item.lastActivityAt?.ISO8601Format()),
            "bound_workspace_id": orNull(item.boundWorkspaceID?.uuidString),
            "bound_workspace_ref": ref(.workspace, item.boundWorkspaceID),
            "bound_workspace_title": orNull(item.boundWorkspaceTitle),
            "bound_window_id": orNull(item.boundWindowID?.uuidString),
            "bound_window_ref": ref(.window, item.boundWindowID),
        ]
        object["target"] = .object([
            "working_directory": orNull(item.targetWorkingDirectory),
            "agent_command": orNull(item.targetAgentCommand),
            "agent": orNull(item.targetAgentName),
        ])
        return .object(object)
    }

    private func queueItemsPayload(_ items: [ControlWorkspaceTaskQueueItem]) -> JSONValue {
        .object([
            "items": .array(items.map(queueItemPayload)),
            "count": .int(Int64(items.count)),
        ])
    }

    private func workspaceTaskQueueList(_ params: [String: JSONValue]) -> ControlCallResult {
        let status = string(params, "status")
        if let status, !["pending", "in-progress", "completed"].contains(status) {
            return .err(
                code: "invalid_params",
                message: "status must be one of: pending, in-progress, completed",
                data: .object(["status": .string(status)])
            )
        }
        switch context?.controlWorkspaceTaskQueueList(
            statusRaw: status,
            workspaceID: uuid(params, "workspace_id")
        ) ?? .tabManagerUnavailable {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .resolved(let items):
            return .ok(queueItemsPayload(items))
        }
    }

    private func workspaceTaskQueueDispatch(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let itemID = queueItemID(params) else {
            return .err(code: "invalid_params", message: "item_id is required", data: nil)
        }
        switch context?.controlWorkspaceTaskQueueDispatch(
            itemID: itemID,
            routing: routingSelectors(params)
        ) ?? .tabManagerUnavailable {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Queue item not found", data: nil)
        case .notDispatchable:
            return .err(code: "invalid_state", message: "Queue item has no dispatch target", data: nil)
        case .created(let item, let workspaceID, let windowID):
            return .ok(.object([
                "item": queueItemPayload(item),
                "created_workspace_id": .string(workspaceID.uuidString),
                "created_workspace_ref": ref(.workspace, workspaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "focused": .bool(false),
            ]))
        }
    }

    private func workspaceTaskQueueReveal(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let itemID = queueItemID(params) else {
            return .err(code: "invalid_params", message: "item_id is required", data: nil)
        }
        switch context?.controlWorkspaceTaskQueueReveal(itemID: itemID) ?? .tabManagerUnavailable {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Queue item not found", data: nil)
        case .revealed(let item):
            return .ok(.object([
                "item": queueItemPayload(item),
                "focused": .bool(false),
                "selected": .bool(false),
            ]))
        }
    }

    private func workspaceTaskQueueSetTarget(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let itemID = queueItemID(params) else {
            return .err(code: "invalid_params", message: "item_id is required", data: nil)
        }
        let target = params["target"]
        let targetObject: [String: JSONValue]?
        if case .object(let object)? = target {
            targetObject = object
        } else {
            targetObject = nil
        }
        let cwd = targetObject.flatMap { string($0, "working_directory") }
        let command = targetObject.flatMap { string($0, "agent_command") }
        let agent = targetObject.flatMap { string($0, "agent") }
        switch context?.controlWorkspaceTaskQueueSetTarget(
            itemID: itemID,
            workingDirectory: cwd,
            agentCommand: command,
            agentName: agent
        ) ?? .tabManagerUnavailable {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Queue item not found", data: nil)
        case .updated(let item):
            return .ok(.object(["item": queueItemPayload(item)]))
        }
    }

    private func queueItemID(_ params: [String: JSONValue]) -> UUID? {
        if let id = uuid(params, "item_id") ?? uuid(params, "id") { return id }
        guard let index = int(params, "index"), index >= 0,
              case .resolved(let items) = context?.controlWorkspaceTaskQueueList(
                  statusRaw: string(params, "status"),
                  workspaceID: uuid(params, "workspace_id")
              ) else { return nil }
        return items.indices.contains(index) ? items[index].id : nil
    }
}
