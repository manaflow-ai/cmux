internal import Foundation

/// The `surface.action` / `tab.action` body: the coordinator parses the params
/// and shapes the payload; the app conformance runs the legacy resolution +
/// mutation order and reports back through ``ControlTabActionResolution``.
extension ControlCommandCoordinator {
    /// The supported `tab.action` keys (the legacy `supportedActions`).
    private static let tabActionSupportedActions = [
        "rename", "clear_name",
        "close_left", "close_right", "close_others",
        "new_terminal_right", "new_browser_right",
        "reload", "duplicate", "move_to_new_workspace", "detach_to_workspace", "detach_to_new_workspace",
        "pin", "unpin", "mark_read", "mark_unread",
    ]

    /// `surface.action` / `tab.action` — run one surface-tab mutation.
    func tabAction(_ params: [String: JSONValue]) -> ControlCallResult {
        let action = actionKey(params)
        let resolution = systemContext?.controlTabAction(
            routing: routingSelectors(params),
            actionKey: action,
            title: string(params, "title"),
            rawURL: string(params, "url"),
            surfaceID: uuid(params, "surface_id") ?? uuid(params, "tab_id"),
            requestedFocus: bool(params, "focus") ?? false,
            moveParams: params
        ) ?? .tabManagerUnavailable

        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .missingAction:
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noFocusedTab:
            return .err(code: "not_found", message: "No focused tab", data: nil)
        case .tabNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: "Tab not found",
                data: .object([
                    "surface_id": .string(surfaceID.uuidString),
                    "surface_ref": ref(.surface, surfaceID),
                    "tab_id": .string(surfaceID.uuidString),
                    "tab_ref": tabRef(surfaceID),
                ])
            )
        case .unknownAction:
            return .err(
                code: "invalid_params",
                message: "Unknown tab action",
                data: .object([
                    "action": orNull(action),
                    "supported_actions": .array(Self.tabActionSupportedActions.map { .string($0) }),
                ])
            )
        case .invalidTitle:
            return .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
        case .invalidURL(let rawURL):
            return .err(
                code: "invalid_params",
                message: "Invalid URL",
                data: .object(["url": .string(rawURL)])
            )
        case .reloadNotBrowser:
            return .err(code: "invalid_state", message: "Reload is only available for browser tabs", data: nil)
        case .duplicateNotBrowser:
            return .err(code: "invalid_state", message: "Duplicate is only available for browser tabs", data: nil)
        case .browserDisabled(let outcome):
            return browserDisabledResult(outcome)
        case .tabPaneNotFound:
            return .err(code: "not_found", message: "Tab pane not found", data: nil)
        case .tabNotFoundInPane:
            return .err(code: "not_found", message: "Tab not found in pane", data: nil)
        case .createFailed:
            return .err(code: "internal_error", message: "Failed to create tab", data: nil)
        case .duplicateFailed:
            return .err(code: "internal_error", message: "Failed to duplicate tab", data: nil)
        case .bridged(let result):
            return result
        case .completed(let outcome):
            var payload: [String: JSONValue] = [
                "action": orNull(action),
                "window_id": orNull(outcome.windowID?.uuidString),
                "window_ref": ref(.window, outcome.windowID),
                "workspace_id": .string(outcome.workspaceID.uuidString),
                "workspace_ref": ref(.workspace, outcome.workspaceID),
                "surface_id": .string(outcome.surfaceID.uuidString),
                "surface_ref": ref(.surface, outcome.surfaceID),
                "tab_id": .string(outcome.surfaceID.uuidString),
                "tab_ref": tabRef(outcome.surfaceID),
            ]
            if let paneID = outcome.paneID {
                payload["pane_id"] = .string(paneID.uuidString)
                payload["pane_ref"] = ref(.pane, paneID)
            } else {
                payload["pane_id"] = .null
                payload["pane_ref"] = .null
            }
            switch outcome.extras {
            case .none:
                break
            case .title(let title):
                payload["title"] = .string(title)
            case .pinned(let pinned):
                payload["pinned"] = .bool(pinned)
            case .created(let createdID):
                payload["created_surface_id"] = .string(createdID.uuidString)
                payload["created_surface_ref"] = ref(.surface, createdID)
                payload["created_tab_id"] = .string(createdID.uuidString)
                payload["created_tab_ref"] = tabRef(createdID)
            case .routedToRemote:
                // Routed to the remote tmux mirror as `new-window`; the tab
                // arrives via %window-add, so there is no created id yet.
                payload["accepted"] = .bool(true)
                payload["routed"] = .string("remote-tmux")
                payload["created_surface_id"] = .null
                payload["created_surface_ref"] = .null
                payload["created_tab_id"] = .null
                payload["created_tab_ref"] = .null
            case .closed(let closed, let skippedPinned):
                payload["closed"] = .int(Int64(closed))
                payload["skipped_pinned"] = .int(Int64(skippedPinned))
            }
            return .ok(.object(payload))
        }
    }
}
