internal import Foundation

/// `sidebar.group_by`: the per-window workspace sidebar Group By mode.
extension ControlCommandCoordinator {
    /// Dispatches `sidebar.group_by`; returns `nil` for anything else so the
    /// core `handle(_:)` can fall through.
    func handleSidebarGroupBy(_ request: ControlRequest) -> ControlCallResult? {
        guard request.method == "sidebar.group_by" else { return nil }
        return sidebarGroupBy(request.params)
    }

    /// Reads the resolved window's Group By mode, or sets it when `mode` is
    /// given. A data change on that window only: it never focuses, raises or
    /// selects anything, so it is not a focus-intent method. The app owns the
    /// set of valid modes and reports an unknown one as `invalidMode`.
    func sidebarGroupBy(_ params: [String: JSONValue]) -> ControlCallResult {
        let mode = string(params, "mode")?.lowercased()
        if hasNonNull(params, "mode"), mode == nil {
            return .err(code: "invalid_params", message: "mode must be a string: manual, host or status", data: nil)
        }
        guard let context else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        switch context.controlSidebarGroupBy(routing: routingSelectors(params), mode: mode) {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .windowNotFound:
            return .err(code: "not_found", message: "Window not found", data: nil)
        case .invalidMode:
            return .err(
                code: "invalid_params",
                message: "Unknown mode; expected manual, host or status",
                data: .object(["mode": orNull(mode)])
            )
        case let .resolved(windowID, resolvedMode):
            return .ok(.object([
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
                "mode": .string(resolvedMode),
            ]))
        }
    }
}
