#if DEBUG
internal import Foundation

/// The debug/test-only domain, continued from
/// `ControlCommandCoordinator+Debug.swift` (500-line budget): browser, right
/// sidebar, terminal, layout/portal counters, flash, panel-snapshot, and
/// screenshot methods.
extension ControlCommandCoordinator {
    func debugRemoteTmuxSizingSettled() -> ControlCallResult {
        .ok(debugContext?.controlDebugRemoteTmuxSizingSettled() ?? .object(["windows": .array([])]))
    }

    // MARK: - debug.browser.*

    /// `debug.browser.address_bar_focused` — which surface's browser address
    /// bar has focus.
    func debugBrowserAddressBarFocused(_ params: [String: JSONValue]) -> ControlCallResult {
        let requestedSurfaceID = uuid(params, "surface_id") ?? uuid(params, "panel_id")
        let focusedSurfaceID = debugContext?.controlDebugFocusedBrowserAddressBarSurfaceID()

        var payload: [String: JSONValue] = [
            "focused_surface_id": orNull(focusedSurfaceID?.uuidString),
            "focused_surface_ref": ref(.surface, focusedSurfaceID),
            "focused_panel_id": orNull(focusedSurfaceID?.uuidString),
            "focused_panel_ref": ref(.surface, focusedSurfaceID),
            "focused": .bool(focusedSurfaceID != nil),
        ]

        if let requestedSurfaceID {
            payload["surface_id"] = .string(requestedSurfaceID.uuidString)
            payload["surface_ref"] = ref(.surface, requestedSurfaceID)
            payload["panel_id"] = .string(requestedSurfaceID.uuidString)
            payload["panel_ref"] = ref(.surface, requestedSurfaceID)
            payload["focused"] = .bool(focusedSurfaceID == requestedSurfaceID)
        }

        return .ok(.object(payload))
    }

    /// `debug.browser.favicon` — the browser panel's favicon PNG. A documented
    /// passthrough: the body resolves its panel through the still-shared
    /// `v2BrowserWithPanel` helper (the whole `browser.*` domain's resolver),
    /// so params cross the seam whole and the app builds the result. The
    /// fallback is the legacy body's initial (unreachable) value.
    func debugBrowserFavicon(_ params: [String: JSONValue]) -> ControlCallResult {
        debugContext?.controlDebugBrowserFavicon(params: params)
            ?? .err(code: "internal_error", message: "Browser operation failed", data: nil)
    }

    // MARK: - debug.right_sidebar.focus / debug.sidebar.visible

    /// `debug.right_sidebar.focus` — reveal and focus the right sidebar.
    func debugRightSidebarFocus(_ params: [String: JSONValue]) -> ControlCallResult {
        let modeName = string(params, "mode")
        let requestedWindowID = uuid(params, "window_id")
        let focusFirstItem = bool(params, "focus_first_item") ?? true
        // An unwired context reads as `windowNotFound` — unreachable in
        // practice (the composition owner wires the context during init).
        let resolution = debugContext?.controlDebugRightSidebarFocus(
            modeName: modeName,
            windowID: requestedWindowID,
            focusFirstItem: focusFirstItem
        ) ?? .windowNotFound
        switch resolution {
        case .invalidMode(let mode):
            return .err(
                code: "invalid_params",
                message: "Invalid right sidebar mode",
                data: .object(["mode": .string(mode)])
            )
        case .windowNotFound:
            return .err(
                code: "not_found",
                message: "Window not found",
                data: requestedWindowID.map {
                    .object([
                        "window_id": .string($0.uuidString),
                        "window_ref": ref(.window, $0),
                    ])
                }
            )
        case .revealed(let state):
            return .ok(.object([
                "focused": .bool(state.revealed),
                "focus_applied": .bool(state.focusApplied),
                "context_found": .bool(state.contextFound),
                "state_found": .bool(state.stateFound),
                "visible": .bool(state.visible),
                "active_mode": orNull(state.activeMode),
                "mode": .string(state.mode),
                "window_id": orNull(requestedWindowID?.uuidString),
                "window_ref": ref(.window, requestedWindowID),
            ]))
        }
    }

    /// `debug.sidebar.visible` — a window's sidebar visibility.
    func debugSidebarVisible(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let windowID = uuid(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        guard let visible = debugContext?.controlDebugSidebarVisibility(windowID: windowID) else {
            return .err(
                code: "not_found",
                message: "Window not found",
                data: .object([
                    "window_id": .string(windowID.uuidString),
                    "window_ref": ref(.window, windowID),
                ])
            )
        }
        return .ok(.object([
            "window_id": .string(windowID.uuidString),
            "window_ref": ref(.window, windowID),
            "visible": .bool(visible),
        ]))
    }

    // MARK: - debug.terminal.*

    /// `debug.terminal.is_focused` — whether a terminal surface has focus
    /// (shared v1 body).
    func debugIsTerminalFocused(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let surfaceID = string(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = debugContext?.controlDebugIsTerminalFocused(surfaceArgument: surfaceID)
            ?? Self.debugContextUnavailableResponse
        if resp.hasPrefix("ERROR") {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        return .ok(.object([
            "focused": .bool(resp.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true")
        ]))
    }

    /// `debug.terminal.simulate_file_drop` — simulate a file drop onto a
    /// terminal.
    func debugSimulateTerminalFileDrop(_ params: [String: JSONValue]) -> ControlCallResult {
        guard debugContext?.controlDebugTabManagerAvailable() == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = string(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        // Legacy `params["paths"] as? [String]`: only an all-string JSON array
        // bridges; anything else reads as missing.
        var rawPaths: [String]?
        if case .array(let elements)? = params["paths"] {
            let strings = elements.compactMap { element -> String? in
                guard case .string(let value) = element else { return nil }
                return value
            }
            rawPaths = strings.count == elements.count ? strings : nil
        }
        guard let rawPaths else {
            return .err(code: "invalid_params", message: "Missing paths", data: nil)
        }
        let paths = rawPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return .err(code: "invalid_params", message: "paths must not be empty", data: nil)
        }

        let route = (string(params, "route") ?? "text_destination")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let simulationRoute: ControlDebugFileDropRoute
        switch route {
        case "terminal", "direct":
            simulationRoute = .terminal
        case "text", "text_destination", "pane_text":
            simulationRoute = .textDestination
        default:
            return .err(code: "invalid_params", message: "Unknown route", data: .object([
                "route": .string(route)
            ]))
        }
        let payload = (string(params, "payload") ?? "file_urls")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let simulationPayload: ControlDebugFileDropPayloadKind
        switch payload {
        case "file", "files", "file_url", "file_urls":
            simulationPayload = .fileURLs
        case "image", "image_data", "images":
            simulationPayload = .imageData
        default:
            return .err(code: "invalid_params", message: "Unknown payload", data: .object([
                "payload": .string(payload)
            ]))
        }

        let resolution = debugContext?.controlDebugSimulateTerminalFileDrop(
            surfaceArgument: surfaceID,
            paths: paths,
            route: simulationRoute,
            payloadKind: simulationPayload
        ) ?? .panelNotFound
        switch resolution {
        case .panelNotFound:
            return .err(code: "not_found", message: "Terminal surface not found", data: .object([
                "surface_id": .string(surfaceID)
            ]))
        case .imageDataRequiresTerminalRoute:
            return .err(code: "invalid_params", message: "Image data payload requires terminal route", data: .object([
                "route": .string(route),
                "payload": .string(payload),
            ]))
        case .workspaceNotFound(let workspaceID):
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceID.uuidString)
            ]))
        case .terminalDrop(let handled):
            return handled
                ? .ok(.object(["handled": .bool(true), "route": .string("terminal"), "payload": .string(payload)]))
                : .err(code: "internal_error", message: "Terminal drop simulation failed", data: nil)
        case .textDestinationDrop(let handled):
            return handled
                ? .ok(.object(["handled": .bool(true), "route": .string("text_destination"), "payload": .string(payload)]))
                : .err(code: "internal_error", message: "Text destination drop simulation failed", data: nil)
        }
    }

    /// `debug.terminal.read_text` — terminal text as base64 (shared v1 body;
    /// the base64 passes through byte-identically).
    func debugReadTerminalText(_ params: [String: JSONValue]) -> ControlCallResult {
        let surfaceArg = string(params, "surface_id") ?? ""
        let resp = debugContext?.controlDebugReadTerminalText(surfaceArgument: surfaceArg)
            ?? Self.debugContextUnavailableResponse
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let b64 = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .ok(.object(["base64": .string(b64)]))
    }

    /// `debug.terminal.render_stats` — renderer stats (shared v1 body's JSON,
    /// decoded exactly as the legacy wrapper did).
    func debugRenderStats(_ params: [String: JSONValue]) -> ControlCallResult {
        let surfaceArg = string(params, "surface_id") ?? ""
        let resp = debugContext?.controlDebugRenderStats(surfaceArgument: surfaceArg)
            ?? Self.debugContextUnavailableResponse
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let stats = JSONValue(foundationObject: obj) else {
            return .err(code: "internal_error", message: "render_stats JSON decode failed", data: .object([
                "payload": .string(String(jsonStr.prefix(200)))
            ]))
        }
        return .ok(.object(["stats": stats]))
    }

    // MARK: - debug.layout / debug.portal.stats

    /// `debug.layout` — the layout-debug tree (shared v1 body's JSON).
    func debugLayout() -> ControlCallResult {
        let resp = debugContext?.controlDebugLayout() ?? Self.debugContextUnavailableResponse
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let layout = JSONValue(foundationObject: obj) else {
            return .err(code: "internal_error", message: "layout_debug JSON decode failed", data: .object([
                "payload": .string(String(jsonStr.prefix(200)))
            ]))
        }
        return .ok(.object(["layout": layout]))
    }

    /// `debug.portal.stats` — the portal registry's counters. The legacy body
    /// had no failure path (the counters are `String`/`Int` leaves), so an
    /// unbridgeable/unwired read degrades to an empty payload.
    func debugPortalStats() -> ControlCallResult {
        .ok(debugContext?.controlDebugPortalStats() ?? .object([:]))
    }

    // MARK: - debug counters (bonsplit underflow / empty panel)

    /// `debug.bonsplit_underflow.count` — shared v1 counter read.
    func debugBonsplitUnderflowCount() -> ControlCallResult {
        let resp = debugContext?.controlDebugBonsplitUnderflowCount() ?? Self.debugContextUnavailableResponse
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(.object(["count": .int(Int64(n))]))
    }

    /// `debug.bonsplit_underflow.reset` — shared v1 counter reset.
    func debugResetBonsplitUnderflowCount() -> ControlCallResult {
        let resp = debugContext?.controlDebugResetBonsplitUnderflowCount() ?? Self.debugContextUnavailableResponse
        return resp == "OK"
            ? .ok(.object([:]))
            : .err(code: "internal_error", message: resp, data: nil)
    }

    /// `debug.empty_panel.count` — shared v1 counter read.
    func debugEmptyPanelCount() -> ControlCallResult {
        let resp = debugContext?.controlDebugEmptyPanelCount() ?? Self.debugContextUnavailableResponse
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(.object(["count": .int(Int64(n))]))
    }

    /// `debug.empty_panel.reset` — shared v1 counter reset.
    func debugResetEmptyPanelCount() -> ControlCallResult {
        let resp = debugContext?.controlDebugResetEmptyPanelCount() ?? Self.debugContextUnavailableResponse
        return resp == "OK"
            ? .ok(.object([:]))
            : .err(code: "internal_error", message: resp, data: nil)
    }

    // MARK: - debug.notification.focus

    /// `debug.notification.focus` — focus a workspace/surface from a
    /// notification (shared v1 body).
    func debugFocusNotification(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let wsId = string(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        let surfaceId = string(params, "surface_id")
        let args = surfaceId != nil ? "\(wsId) \(surfaceId!)" : wsId
        let resp = debugContext?.controlDebugFocusNotification(arguments: args)
            ?? Self.debugContextUnavailableResponse
        return resp == "OK"
            ? .ok(.object([:]))
            : .err(code: "internal_error", message: resp, data: nil)
    }

    // MARK: - debug.flash.*

    /// `debug.flash.count` — a surface's flash count (shared v1 body).
    func debugFlashCount(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let surfaceID = string(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = debugContext?.controlDebugFlashCount(surfaceArgument: surfaceID)
            ?? Self.debugContextUnavailableResponse
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(.object(["count": .int(Int64(n))]))
    }

    /// `debug.flash.reset` — reset all flash counts (shared v1 body).
    func debugResetFlashCounts() -> ControlCallResult {
        let resp = debugContext?.controlDebugResetFlashCounts() ?? Self.debugContextUnavailableResponse
        return resp == "OK"
            ? .ok(.object([:]))
            : .err(code: "internal_error", message: resp, data: nil)
    }

    // MARK: - debug.panel_snapshot.*

    /// `debug.panel_snapshot` — capture a panel pixel snapshot (shared v1
    /// body; the coordinator parses its 5-field response line).
    func debugPanelSnapshot(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let surfaceID = string(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let label = string(params, "label") ?? ""
        let args = label.isEmpty ? surfaceID : "\(surfaceID) \(label)"
        let resp = debugContext?.controlDebugPanelSnapshot(arguments: args)
            ?? Self.debugContextUnavailableResponse
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 4).map(String.init)
        guard parts.count == 5 else {
            return .err(code: "internal_error", message: "panel_snapshot parse failed", data: .object([
                "payload": .string(payload)
            ]))
        }
        return .ok(.object([
            "surface_id": .string(parts[0]),
            "changed_pixels": .int(Int64(Int(parts[1]) ?? -1)),
            "width": .int(Int64(Int(parts[2]) ?? 0)),
            "height": .int(Int64(Int(parts[3]) ?? 0)),
            "path": .string(parts[4]),
        ]))
    }

    /// `debug.panel_snapshot.reset` — reset a panel's snapshot baseline
    /// (shared v1 body).
    func debugPanelSnapshotReset(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let surfaceID = string(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = debugContext?.controlDebugPanelSnapshotReset(surfaceArgument: surfaceID)
            ?? Self.debugContextUnavailableResponse
        return resp == "OK"
            ? .ok(.object([:]))
            : .err(code: "internal_error", message: resp, data: nil)
    }

    // MARK: - debug.window.screenshot

    /// `debug.window.screenshot` — capture a window screenshot (shared v1
    /// body; the coordinator parses its 2-field response line).
    func debugScreenshot(_ params: [String: JSONValue]) -> ControlCallResult {
        let label = string(params, "label") ?? ""
        let resp = debugContext?.controlDebugCaptureScreenshot(label: label)
            ?? Self.debugContextUnavailableResponse
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return .err(code: "internal_error", message: "screenshot parse failed", data: .object([
                "payload": .string(payload)
            ]))
        }
        return .ok(.object([
            "screenshot_id": .string(parts[0]),
            "path": .string(parts[1]),
        ]))
    }
}
#endif
