internal import Foundation

/// Workspace-todo set/open verbs extracted from the primary workspace-todo coordinator file, which sits at its file-length budget.
extension ControlCommandCoordinator {
    /// The up-front parse of `workspace.todo.set`'s `items` array: either
    /// every element parsed, or the error to reply with (atomicity: nothing
    /// crosses the seam on a malformed request).
    private enum WorkspaceTodoSetItemsParse {
        case items([ControlWorkspaceTodoSetItemParam])
        case invalid(ControlCallResult)
    }

    private func workspaceTodoSetItems(
        _ params: [String: JSONValue]
    ) -> WorkspaceTodoSetItemsParse {
        guard case .array(let rawItems)? = params["items"] else {
            return .invalid(.err(code: "invalid_params", message: "Missing or invalid items", data: nil))
        }
        var items: [ControlWorkspaceTodoSetItemParam] = []
        items.reserveCapacity(rawItems.count)
        for (index, rawItem) in rawItems.enumerated() {
            guard case .object(let object) = rawItem else {
                return .invalid(.err(
                    code: "invalid_params",
                    message: "items[\(index)] must be an object",
                    data: nil
                ))
            }
            guard case .string(let text)? = object["text"] else {
                return .invalid(.err(
                    code: "invalid_params",
                    message: "items[\(index)].text is required",
                    data: nil
                ))
            }
            var itemID: UUID?
            if let rawID = object["id"], rawID != .null {
                guard case .string(let idString) = rawID,
                      let parsed = UUID(uuidString: idString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return .invalid(.err(
                        code: "invalid_params",
                        message: "items[\(index)].id must be an item UUID",
                        data: nil
                    ))
                }
                itemID = parsed
            }
            items.append(ControlWorkspaceTodoSetItemParam(
                id: itemID,
                text: text,
                stateRaw: string(object, "state"),
                originRaw: string(object, "origin")
            ))
        }
        return .items(items)
    }

    /// `workspace.todo.set` — atomic identity-preserving replace; replies
    /// with the resulting list payload.
    func workspaceTodoSet(_ params: [String: JSONValue]) -> ControlCallResult {
        let items: [ControlWorkspaceTodoSetItemParam]
        switch workspaceTodoSetItems(params) {
        case .invalid(let error):
            return error
        case .items(let parsed):
            items = parsed
        }
        let resolution = context?.controlWorkspaceTodoSet(
            routing: routingSelectors(params),
            workspaceID: uuid(params, "workspace_id"),
            items: items
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .emptyText(let index):
            return .err(
                code: "invalid_params",
                message: "items[\(index)].text must not be empty",
                data: .object(["index": .int(Int64(index))])
            )
        case .tooManyItems(let count):
            return .err(
                code: "invalid_params",
                message: "items exceeds the checklist cap of 50",
                data: .object(["count": .int(Int64(count))])
            )
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
        case .resolved(let windowID, let checklist):
            return .ok(workspaceTodoListPayload(windowID: windowID, checklist: checklist))
        }
    }

    /// `workspace.todo.open` — open (or focus) the workspace's todo pane.
    func workspaceTodoOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlWorkspaceTodoOpen(
            routing: routingSelectors(params),
            workspaceID: uuid(params, "workspace_id"),
            requestedFocus: bool(params, "focus") ?? true
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .openFailed:
            return .err(code: "internal_error", message: "Failed to open todo pane", data: nil)
        case .opened(let windowID, let workspaceID, let paneID, let surfaceID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": orNull(paneID?.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }
}
