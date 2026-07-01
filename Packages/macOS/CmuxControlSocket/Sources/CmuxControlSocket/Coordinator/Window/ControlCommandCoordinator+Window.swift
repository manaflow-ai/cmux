internal import Foundation

/// The window domain (`window.*`), lifted byte-faithfully from the former
/// `TerminalController.v2Window*` bodies. Each payload is built directly as a
/// ``JSONValue`` (the typed twin of the legacy `[String: Any]` dictionaries);
/// the resulting Foundation object is identical, so the encoded wire bytes
/// match.
extension ControlCommandCoordinator {
    /// Dispatches the window methods this coordinator owns; returns `nil` for
    /// anything else so the core `handle(_:)` can fall through.
    func handleWindow(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "window.list":
            return windowList()
        case "window.current":
            return windowCurrent(request.params)
        case "window.focus":
            return windowFocus(request.params)
        case "window.create":
            return windowCreate()
        case "window.close":
            return windowClose(request.params)
        case "window.displays":
            return windowDisplays()
        case "window.display":
            return windowDisplay(request.params)
        default:
            return nil
        }
    }

    /// `window.list` — every main window, in order.
    func windowList() -> ControlCallResult {
        let windows = context?.controlWindowSummaries() ?? []
        let payload: [JSONValue] = windows.enumerated().map { index, item in
            .object([
                "id": .string(item.windowID.uuidString),
                "ref": ref(.window, item.windowID),
                "index": .int(Int64(index)),
                "key": .bool(item.isKeyWindow),
                "visible": .bool(item.isVisible),
                "workspace_count": .int(Int64(item.workspaceCount)),
                "selected_workspace_id": orNull(item.selectedWorkspaceID?.uuidString),
                "selected_workspace_ref": ref(.workspace, item.selectedWorkspaceID),
            ])
        }
        return .ok(.object(["windows": .array(payload)]))
    }

    /// `window.current` — the window resolved from the routing selectors.
    func windowCurrent(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlResolveCurrentWindow(routing: routingSelectors(params))
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .windowNotFound:
            return .err(code: "not_found", message: "Current window not found", data: nil)
        case .resolved(let windowID):
            return .ok(.object([
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    /// `window.focus` — focus a window by id.
    func windowFocus(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let windowID = uuid(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let ok = context?.controlFocusWindow(id: windowID) ?? false
        let identity: JSONValue = .object([
            "window_id": .string(windowID.uuidString),
            "window_ref": ref(.window, windowID),
        ])
        return ok
            ? .ok(identity)
            : .err(code: "not_found", message: "Window not found", data: identity)
    }

    /// `window.create` — create a window and make it active.
    func windowCreate() -> ControlCallResult {
        guard let windowID = context?.controlCreateWindowAndActivate() else {
            return .err(code: "internal_error", message: "Failed to create window", data: nil)
        }
        return .ok(.object([
            "window_id": .string(windowID.uuidString),
            "window_ref": ref(.window, windowID),
        ]))
    }

    /// `window.close` — close a window by id.
    func windowClose(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let windowID = uuid(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let ok = context?.controlCloseWindow(id: windowID) ?? false
        let identity: JSONValue = .object([
            "window_id": .string(windowID.uuidString),
            "window_ref": ref(.window, windowID),
        ])
        return ok
            ? .ok(identity)
            : .err(code: "not_found", message: "Window not found", data: identity)
    }

    /// `window.displays` — every connected display.
    func windowDisplays() -> ControlCallResult {
        let displays = context?.controlAvailableDisplays() ?? []
        let payload: [JSONValue] = displays.map { display in
            .object([
                "name": .string(display.name),
                "index": .int(Int64(display.index)),
                "display_id": display.displayID.map { JSONValue.int(Int64(Int($0))) } ?? .null,
                "main": .bool(display.isMain),
                "frame": .object([
                    "x": .int(Int64(Int(display.frameX))),
                    "y": .int(Int64(Int(display.frameY))),
                    "width": .int(Int64(Int(display.frameWidth))),
                    "height": .int(Int64(Int(display.frameHeight))),
                ]),
            ])
        }
        return .ok(.object(["displays": .array(payload)]))
    }

    /// `window.display` — move one window (or all windows) onto a display.
    func windowDisplay(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let displayQuery = string(params, "display") else {
            return .err(code: "invalid_params", message: "Missing or invalid display", data: nil)
        }

        // Explicit window target moves just that window; otherwise move every
        // main window of this instance (a dev build usually has one).
        if let windowID = uuid(params, "window_id") {
            if let display = context?.controlMoveWindow(id: windowID, toDisplayMatching: displayQuery) {
                return .ok(.object([
                    "display": .string(display),
                    "window_id": .string(windowID.uuidString),
                    "window_ref": ref(.window, windowID),
                    "moved": .array([.string(windowID.uuidString)]),
                ]))
            }
            let windowExists = context?.controlWindowExists(id: windowID) ?? false
            if !windowExists {
                return .err(code: "not_found", message: "Window not found", data: .object([
                    "window_id": .string(windowID.uuidString),
                    "window_ref": ref(.window, windowID),
                ]))
            }
            return displayNotFound(displayQuery)
        }

        guard let result = context?.controlMoveAllWindows(toDisplayMatching: displayQuery) else {
            return displayNotFound(displayQuery)
        }
        return .ok(.object([
            "display": .string(result.display),
            "moved": .array(result.windowIDs.map { .string($0.uuidString) }),
        ]))
    }

    /// The shared `display not found` error for `window.display`, carrying the
    /// requested query and the available display names.
    private func displayNotFound(_ requested: String) -> ControlCallResult {
        let names = (context?.controlAvailableDisplays() ?? []).map(\.name)
        return .err(
            code: "not_found",
            message: "Display not found: \(requested)",
            data: .object([
                "requested": .string(requested),
                "available": .array(names.map { .string($0) }),
            ])
        )
    }
}
