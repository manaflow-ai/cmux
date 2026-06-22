internal import Foundation

/// The remaining surface-domain bodies (move/reorder/refresh/clear_history/
/// trigger_flash/send_text/send_key/read_text/resume.*/report_*/ports_kick and the
/// `debug.terminals` passthrough), split out of
/// `ControlCommandCoordinator+Surface.swift` to keep each file under the 500-line
/// budget. See that file's doc comment for the domain overview.
extension ControlCommandCoordinator {

    // MARK: - move

    /// `surface.move` — move a surface (delegates to the still-app-side
    /// surface-move logic; the app bridges the result byte-faithfully).
    func surfaceMove(_ params: [String: JSONValue]) -> ControlCallResult {
        context?.controlSurfaceMove(params: params)
            ?? .err(code: "internal_error", message: "Failed to move surface", data: nil)
    }

    // MARK: - reorder

    /// `surface.reorder` — reorder a surface within its pane.
    func surfaceReorder(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let index = int(params, "index")
        let beforeSurfaceID = uuid(params, "before_surface_id")
        let afterSurfaceID = uuid(params, "after_surface_id")
        let targetCount = (index != nil ? 1 : 0)
            + (beforeSurfaceID != nil ? 1 : 0)
            + (afterSurfaceID != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(
                code: "invalid_params",
                message: "Specify exactly one of index, before_surface_id, or after_surface_id",
                data: nil
            )
        }

        let inputs = ControlSurfaceReorderInputs(
            index: index,
            beforeSurfaceID: beforeSurfaceID,
            afterSurfaceID: afterSurfaceID
        )
        let resolution = context?.controlSurfaceReorder(
            surfaceID: surfaceID,
            inputs: inputs,
            requestedFocus: bool(params, "focus") ?? false
        ) ?? .surfaceNotFound(surfaceID)
        switch resolution {
        case .surfaceNotFound(let id):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .anchorNotInSamePane:
            return .err(code: "invalid_params", message: "Anchor surface must be in the same pane", data: nil)
        case .reorderFailed:
            return .err(code: "internal_error", message: "Failed to reorder surface", data: nil)
        case .reordered(let windowID, let workspaceID, let paneID, let surfaceID):
            return .ok(.object([
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }

    // MARK: - refresh

    /// `surface.refresh` — force-refresh every terminal surface.
    func surfaceRefresh(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlSurfaceRefresh(routing: routing) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .refreshed(let windowID, let workspaceID, let refreshedCount):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "refreshed": .int(Int64(refreshedCount)),
            ]))
        }
    }

    // MARK: - clear_history

    /// `surface.clear_history` — clear a terminal surface's screen/history.
    func surfaceClearHistory(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlSurfaceClearHistory(
            routing: routing,
            surfaceID: uuid(params, "surface_id"),
            hasSurfaceIDParam: params["surface_id"] != nil
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFoundForID:
            return .err(code: "not_found", message: "Surface not found for the given surface_id", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .surfaceNotTerminal(let id):
            return .err(
                code: "invalid_params",
                message: "Surface is not a terminal",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .bindingActionUnavailable:
            return .err(code: "not_supported", message: "clear_screen binding action is unavailable", data: nil)
        case .cleared(let windowID, let workspaceID, let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - trigger_flash

    /// `surface.trigger_flash` — flash a surface's focus indicator.
    func surfaceTriggerFlash(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlSurfaceTriggerFlash(
            routing: routing,
            surfaceID: uuid(params, "surface_id")
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .surfaceNotFound(let id):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .flashed(let windowID, let workspaceID, let surfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - send_text / send_key

    /// `surface.send_text` — inject literal text into a terminal surface.
    func surfaceSendText(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        // Legacy `params["text"] as? String` (no trim, no ref/UUID handling).
        guard case .string(let text)? = params["text"] else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let resolution = context?.controlSurfaceSendText(
            routing: routing,
            surfaceID: uuid(params, "surface_id"),
            hasSurfaceIDParam: params["surface_id"] != nil,
            text: text
        ) ?? .tabManagerUnavailable
        return surfaceSendResult(resolution)
    }

    /// `surface.send_key` — send a named key to a terminal surface.
    func surfaceSendKey(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        let resolution = context?.controlSurfaceSendKey(
            routing: routing,
            surfaceID: uuid(params, "surface_id"),
            hasSurfaceIDParam: params["surface_id"] != nil,
            key: key
        ) ?? .tabManagerUnavailable
        return surfaceSendResult(resolution, key: key)
    }

    /// Shapes the shared send-text / send-key result, selecting the localized
    /// terminal-input error messages from the app-resolved strings.
    private func surfaceSendResult(
        _ resolution: ControlSurfaceSendResolution,
        key: String? = nil
    ) -> ControlCallResult {
        let strings = context?.controlSurfaceInputStrings()
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFoundForID:
            return .err(code: "not_found", message: "Surface not found for the given surface_id", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .surfaceNotTerminal(let id):
            return .err(
                code: "invalid_params",
                message: "Surface is not a terminal",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .unknownKey:
            return .err(
                code: "invalid_params",
                message: "Unknown key",
                data: .object(["key": .string(key ?? "")])
            )
        case .inputQueueFull(let id):
            return .err(
                code: "input_queue_full",
                message: strings?.inputQueueFull ?? "",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .surfaceUnavailable(let id):
            return .err(
                code: "surface_unavailable",
                message: strings?.surfaceUnavailable ?? "",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .processExited(let id):
            return .err(
                code: "process_exited",
                message: strings?.processExited ?? "",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .sent(let windowID, let workspaceID, let surfaceID, let queued):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "queued": .bool(queued),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - read_text

    /// `surface.read_text` — read a terminal surface's visible / scrollback text.
    func surfaceReadText(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var includeScrollback = bool(params, "scrollback") ?? false
        let lineLimit = int(params, "lines")
        if let lineLimit, lineLimit <= 0 {
            return .err(code: "invalid_params", message: "lines must be greater than 0", data: nil)
        }
        let resolution = context?.controlSurfaceReadText(
            routing: routing,
            surfaceID: uuid(params, "surface_id"),
            hasSurfaceIDParam: params["surface_id"] != nil,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) ?? .internalError(message: "Failed to read terminal text")
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFoundForID:
            return .err(code: "not_found", message: "Surface not found for the given surface_id", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .surfaceNotTerminal(let id):
            return .err(
                code: "invalid_params",
                message: "Surface is not a terminal",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .internalError(let message):
            return .err(code: "internal_error", message: message, data: nil)
        case .read(let text, let base64, let windowID, let workspaceID, let surfaceID):
            return .ok(.object([
                "text": .string(text),
                "base64": .string(base64),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - debug.terminals

    /// `debug.terminals` — the global terminal-surface debug table. The payload is
    /// dozens of irreducibly app-coupled `NSWindow`/`NSView`/Ghostty-pointer
    /// fields, so the app returns it already bridged to a ``JSONValue`` (the
    /// documented single-method passthrough exception).
    func debugTerminals(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let payload = context?.controlDebugTerminals() else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }

    // MARK: - helpers

}
