internal import Foundation

extension ControlCommandCoordinator {
    /// Dispatches the `layout.*` methods this coordinator owns.
    func handleLayout(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "layout.save":
            return layoutSave(request.params)
        case "layout.list":
            return layoutList(request.params)
        case "layout.get":
            return layoutGet(request.params)
        case "layout.open":
            return layoutOpen(request.params)
        case "layout.delete":
            return layoutDelete(request.params)
        default:
            return nil
        }
    }

    private func layoutSave(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let name = string(params, "name") else {
            return .err(code: "invalid_params", message: "Missing or blank name", data: nil)
        }
        guard let context else {
            return .err(code: "unavailable", message: "Saved layout context not available", data: nil)
        }
        let workspaceID = uuidAny(params["workspace_id"]) ?? uuidAny(params["workspace_ref"])
        // A workspace selector that is present but unresolvable must error, not
        // silently capture the focused workspace.
        if workspaceID == nil, hasNonNull(params, "workspace_id") || hasNonNull(params, "workspace_ref") {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        let resolution = context.controlLayoutSave(
            routing: routingSelectors(params),
            workspaceID: workspaceID,
            name: name,
            description: optionalTrimmedRawString(params, "description"),
            overwrite: bool(params, "overwrite") ?? false
        )
        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .alreadyExists:
            return .err(code: "already_exists", message: "Layout already exists", data: .object(["name": .string(name)]))
        case .corruptFile(let description):
            return .err(code: "invalid_state", message: "layouts.json is corrupt", data: .object(["description": .string(description)]))
        case .saved(let savedName, let path, let unsupportedSurfaceCount):
            return .ok(.object([
                "name": .string(savedName),
                "path": .string(path),
                "unsupported_surface_count": .int(Int64(unsupportedSurfaceCount)),
            ]))
        case .failed(let message):
            return .err(code: "internal_error", message: message, data: nil)
        }
    }

    private func layoutList(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "Saved layout context not available", data: nil)
        }
        let resolution = context.controlLayoutList()
        switch resolution {
        case .corruptFile(let description):
            return .err(code: "invalid_state", message: "layouts.json is corrupt", data: .object(["description": .string(description)]))
        case .resolved(let layouts):
            return .ok(.object([
                "layouts": .array(layouts.map { summary in
                    .object([
                        "name": .string(summary.name),
                        "description": orNull(summary.description),
                        "pane_count": .int(Int64(summary.paneCount)),
                        "surface_count": .int(Int64(summary.surfaceCount)),
                    ])
                }),
            ]))
        case .failed(let message):
            return .err(code: "internal_error", message: message, data: nil)
        }
    }

    private func layoutGet(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let name = string(params, "name") else {
            return .err(code: "invalid_params", message: "Missing or blank name", data: nil)
        }
        let resolution = context?.controlLayoutGet(name: name) ?? .notFound
        switch resolution {
        case .notFound:
            return .err(code: "not_found", message: "Layout not found", data: .object(["name": .string(name)]))
        case .corruptFile(let description):
            return .err(code: "invalid_state", message: "layouts.json is corrupt", data: .object(["description": .string(description)]))
        case .resolved(let payload):
            return .ok(payload)
        case .failed(let message):
            return .err(code: "internal_error", message: message, data: nil)
        }
    }

    private func layoutOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let name = string(params, "name") else {
            return .err(code: "invalid_params", message: "Missing or blank name", data: nil)
        }
        let resolution = context?.controlLayoutOpen(
            routing: routingSelectors(params),
            name: name,
            cwd: optionalTrimmedRawString(params, "cwd"),
            focusRequested: bool(params, "focus") ?? false
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .layoutNotFound:
            return .err(code: "not_found", message: "Layout not found", data: .object(["name": .string(name)]))
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .corruptFile(let description):
            return .err(code: "invalid_state", message: "layouts.json is corrupt", data: .object(["description": .string(description)]))
        case .opened(let workspaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .failed(let message):
            return .err(code: "internal_error", message: message, data: nil)
        }
    }

    private func layoutDelete(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let name = string(params, "name") else {
            return .err(code: "invalid_params", message: "Missing or blank name", data: nil)
        }
        let resolution = context?.controlLayoutDelete(name: name) ?? .notFound
        switch resolution {
        case .notFound:
            return .err(code: "not_found", message: "Layout not found", data: .object(["name": .string(name)]))
        case .corruptFile(let description):
            return .err(code: "invalid_state", message: "layouts.json is corrupt", data: .object(["description": .string(description)]))
        case .deleted:
            return .ok(.object(["deleted": .bool(true)]))
        case .failed(let message):
            return .err(code: "internal_error", message: message, data: nil)
        }
    }
}
