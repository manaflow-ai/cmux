internal import Foundation

/// The workstream domain (`workstream.*`): the top-level drill-in containers
/// that sit a level above `workspace.group.*`. Mirrors the workspace-group
/// handler's shape — each payload is built directly as a ``JSONValue`` so the
/// encoded wire bytes are stable.
extension ControlCommandCoordinator {
    /// Dispatches the workstream methods this coordinator owns; returns `nil`
    /// for anything else so the core `handle(_:)` can fall through.
    func handleWorkstream(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "workstream.list":
            return workstreamList(request.params)
        case "workstream.create":
            return workstreamCreate(request.params)
        case "workstream.rename":
            return workstreamRename(request.params)
        case "workstream.delete":
            return workstreamDelete(request.params)
        case "workstream.add":
            return workstreamAdd(request.params)
        case "workstream.remove":
            return workstreamRemove(request.params)
        case "workstream.move":
            return workstreamMove(request.params)
        case "workstream.enter":
            return workstreamEnter(request.params)
        case "workstream.exit":
            return workstreamExit(request.params)
        default:
            return nil
        }
    }

    // MARK: - Payload

    private func workstreamPayload(_ workstream: ControlWorkstreamSnapshot) -> JSONValue {
        .object([
            "id": .string(workstream.id.uuidString),
            "ref": ref(.workstream, workstream.id),
            "name": .string(workstream.name),
            "custom_color": orNull(workstream.customColor),
            "icon_symbol": orNull(workstream.iconSymbol),
            "member_workspace_ids": .array(workstream.memberWorkspaceIDs.map { .string($0.uuidString) }),
            "member_workspace_refs": .array(workstream.memberWorkspaceIDs.map { ref(.workspace, $0) }),
            "workspace_count": .int(Int64(workstream.memberWorkspaceIDs.count)),
        ])
    }

    // MARK: - List

    /// `workstream.list` — every workstream in the resolved window.
    func workstreamList(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlWorkstreamList(routing: routingSelectors(params))
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .resolved(let windowID, let workstreams, let drilledInID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "drilled_in_workstream_id": orNull(drilledInID?.uuidString),
                "drilled_in_workstream_ref": ref(.workstream, drilledInID),
                "workstreams": .array(workstreams.map { workstreamPayload($0) }),
            ]))
        }
    }

    // MARK: - Create

    /// `workstream.create` — create a workstream from explicit member workspaces.
    func workstreamCreate(_ params: [String: JSONValue]) -> ControlCallResult {
        let name = rawString(params, "name") ?? ""

        let rawWorkspaces: [String]
        if let provided = workstreamStringArrayExact(params["workspace_ids"]) {
            rawWorkspaces = provided
        } else if let value = params["workspace_ids"], !workstreamIsNull(value) {
            return .err(
                code: "invalid_params",
                message: "workspace_ids must be an array of workspace handles",
                data: .object(["workspace_ids": .string(String(describing: value.foundationObject))])
            )
        } else {
            rawWorkspaces = []
        }

        var unresolved: [String] = []
        let parsedWorkspaceIDs: [UUID] = rawWorkspaces.compactMap { raw -> UUID? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let uuid = uuidAny(.string(trimmed)) { return uuid }
            unresolved.append(trimmed)
            return nil
        }
        if !unresolved.isEmpty {
            return .err(
                code: "invalid_params",
                message: "Unresolved workspace handles: \(unresolved.joined(separator: ", "))",
                data: .object(["unresolved": .array(unresolved.map { .string($0) })])
            )
        }

        let resolution = context?.controlCreateWorkstream(
            routing: routingSelectors(params),
            name: name,
            workspaceIDs: parsedWorkspaceIDs
        ) ?? .tabManagerUnavailable

        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound(let missing):
            return .err(
                code: "not_found",
                message: "Workspace not found in target window: \(missing.joined(separator: ", "))",
                data: .object(["unknown_workspace_ids": .array(missing.map { .string($0) })])
            )
        case .created(let workstream):
            return .ok(.object(["workstream": workstreamPayload(workstream)]))
        }
    }

    // MARK: - Rename / Delete

    /// `workstream.rename` — rename a workstream.
    func workstreamRename(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let id = uuid(params, "workstream_id"),
              let name = string(params, "name") else {
            return .err(code: "invalid_params", message: "Missing workstream_id or name", data: nil)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .err(code: "invalid_params", message: "Missing workstream_id or name", data: nil)
        }
        guard let ok = context?.controlRenameWorkstream(
            routing: routingSelectors(params),
            workstreamID: id,
            name: trimmedName
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["workstream_id": .string(id.uuidString), "name": .string(trimmedName)]))
            : .err(code: "not_found", message: "Workstream not found", data: .object(["workstream_id": .string(id.uuidString)]))
    }

    /// `workstream.delete` — dissolve a workstream, keeping its workspaces.
    func workstreamDelete(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let id = uuid(params, "workstream_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workstream_id", data: nil)
        }
        guard let released = context?.controlDeleteWorkstream(routing: routingSelectors(params), workstreamID: id) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard released >= 0 else {
            return .err(code: "not_found", message: "Workstream not found", data: .object(["workstream_id": .string(id.uuidString)]))
        }
        return .ok(.object([
            "workstream_id": .string(id.uuidString),
            "released_workspace_count": .int(Int64(released)),
        ]))
    }

    // MARK: - Membership

    /// `workstream.add` — move a workspace into a workstream.
    func workstreamAdd(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let id = uuid(params, "workstream_id"),
              let wsId = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing workstream_id or workspace_id", data: nil)
        }
        let identity: JSONValue = .object([
            "workstream_id": .string(id.uuidString),
            "workspace_id": .string(wsId.uuidString),
        ])
        guard let ok = context?.controlAddWorkspaceToWorkstream(
            routing: routingSelectors(params), workstreamID: id, workspaceID: wsId
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(identity)
            : .err(code: "not_found", message: "Workstream or workspace not found", data: identity)
    }

    /// `workstream.remove` — remove a workspace from its workstream.
    func workstreamRemove(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let wsId = uuid(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let ok = context?.controlRemoveWorkspaceFromWorkstream(routing: routingSelectors(params), workspaceID: wsId) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["workspace_id": .string(wsId.uuidString)]))
            : .err(code: "not_found", message: "Workspace not in a workstream", data: .object(["workspace_id": .string(wsId.uuidString)]))
    }

    // MARK: - Move

    /// `workstream.move` — reorder a workstream in the master list.
    func workstreamMove(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let id = uuid(params, "workstream_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workstream_id", data: nil)
        }
        guard let ok = context?.controlMoveWorkstream(
            routing: routingSelectors(params),
            workstreamID: id,
            toIndex: int(params, "to_index"),
            beforeWorkstreamID: uuid(params, "before_workstream_id"),
            afterWorkstreamID: uuid(params, "after_workstream_id")
        ) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["workstream_id": .string(id.uuidString)]))
            : .err(
                code: "invalid_params",
                message: "Missing or unresolvable target position",
                data: .object(["workstream_id": .string(id.uuidString)])
            )
    }

    // MARK: - Drill-in navigation

    /// `workstream.enter` — drill into a workstream (view-state only).
    func workstreamEnter(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let id = uuid(params, "workstream_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workstream_id", data: nil)
        }
        guard let ok = context?.controlEnterWorkstream(routing: routingSelectors(params), workstreamID: id) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return ok
            ? .ok(.object(["workstream_id": .string(id.uuidString), "drilled_in": .bool(true)]))
            : .err(code: "not_found", message: "Workstream not found", data: .object(["workstream_id": .string(id.uuidString)]))
    }

    /// `workstream.exit` — return to the top-level workstream list.
    func workstreamExit(_ params: [String: JSONValue]) -> ControlCallResult {
        guard context?.controlExitWorkstreamDrillIn(routing: routingSelectors(params)) != nil else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return .ok(.object(["drilled_in": .bool(false)]))
    }

    // MARK: - Local helpers

    private func workstreamStringArrayExact(_ value: JSONValue?) -> [String]? {
        guard case .array(let elements)? = value else { return nil }
        var out: [String] = []
        out.reserveCapacity(elements.count)
        for element in elements {
            guard case .string(let string) = element else { return nil }
            out.append(string)
        }
        return out
    }

    private func workstreamIsNull(_ value: JSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }
}
