internal import Foundation

/// The debug/test-only domain (`debug.*` main-actor methods), lifted
/// byte-faithfully from the former `TerminalController.v2Debug*` bodies. Each
/// payload is built directly as a ``JSONValue``; the encoded wire bytes match.
///
/// Every method here was dispatched from inside `#if DEBUG` in the legacy
/// switch, so the whole domain is DEBUG-gated end to end (handler, seam,
/// conformance): in release builds `handleDebug` returns `nil` and the
/// legacy dispatcher's `default:` produces the same `method_not_found` the
/// compiled-out cases always did. The worker-lane
/// `debug.sidebar.simulate_drag` and the shared `debug.terminals` stay
/// app-side/surface-domain and are NOT handled here.
///
/// This file carries the dispatch plus the session-snapshot, shortcut, input,
/// text-box, and command-palette methods; the rest live in `+Debug2.swift`
/// (500-line budget).
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the debug domain, returning
    /// the typed result; returns `nil` otherwise so the caller can fall
    /// through. The integrator calls this from the core `handle`.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a debug method (or in a
    ///   release build, where the domain does not exist).
    func handleDebug(_ request: ControlRequest) -> ControlCallResult? {
#if DEBUG
        switch request.method {
        case "debug.session_snapshot_benchmark":
            return debugSessionSnapshotBenchmark(request.params)
        case "debug.session_snapshot_seed_scrollback":
            return debugSessionSnapshotSeedScrollback(request.params)
        case "debug.shortcut.set":
            return debugShortcutSet(request.params)
        case "debug.shortcut.simulate":
            return debugShortcutSimulate(request.params)
        case "debug.type":
            return debugType(request.params)
        case "debug.textbox.inline_fixture":
            return debugTextBoxInlineFixture(request.params)
        case "debug.textbox.interact":
            return debugTextBoxInteract(request.params)
        case "debug.app.activate":
            return debugActivateApp()
        case "debug.workspace_todo.checklist_add_field":
            return debugWorkspaceTodoChecklistAddField()
        case "debug.command_palette.toggle":
            return debugCommandPaletteEvent(.toggle, request.params)
        case "debug.command_palette.rename_tab.open":
            return debugCommandPaletteEvent(.renameTabOpen, request.params)
        case "debug.command_palette.visible":
            return debugCommandPaletteVisible(request.params)
        case "debug.command_palette.selection":
            return debugCommandPaletteSelection(request.params)
        case "debug.command_palette.results":
            return debugCommandPaletteResults(request.params)
        case "debug.command_palette.rename_input.interact":
            return debugCommandPaletteEvent(.renameInputInteraction, request.params)
        case "debug.command_palette.rename_input.delete_backward":
            return debugCommandPaletteEvent(.renameInputDeleteBackward, request.params)
        case "debug.command_palette.rename_input.selection":
            return debugCommandPaletteRenameInputSelection(request.params)
        case "debug.command_palette.rename_input.select_all":
            return debugCommandPaletteRenameInputSelectAll(request.params)
        case "debug.browser.address_bar_focused":
            return debugBrowserAddressBarFocused(request.params)
        case "debug.browser.favicon":
            return debugBrowserFavicon(request.params)
        case "debug.right_sidebar.focus":
            return debugRightSidebarFocus(request.params)
        case "debug.sidebar.visible":
            return debugSidebarVisible(request.params)
        case "debug.terminal.is_focused":
            return debugIsTerminalFocused(request.params)
        case "debug.terminal.simulate_file_drop":
            return debugSimulateTerminalFileDrop(request.params)
        case "debug.terminal.read_text":
            return debugReadTerminalText(request.params)
        case "debug.terminal.render_stats":
            return debugRenderStats(request.params)
        case "debug.layout":
            return debugLayout()
        case "debug.portal.stats":
            return debugPortalStats()
        case "debug.bonsplit_underflow.count":
            return debugBonsplitUnderflowCount()
        case "debug.bonsplit_underflow.reset":
            return debugResetBonsplitUnderflowCount()
        case "debug.empty_panel.count":
            return debugEmptyPanelCount()
        case "debug.empty_panel.reset":
            return debugResetEmptyPanelCount()
        case "debug.notification.focus":
            return debugFocusNotification(request.params)
        case "debug.flash.count":
            return debugFlashCount(request.params)
        case "debug.flash.reset":
            return debugResetFlashCounts()
        case "debug.panel_snapshot":
            return debugPanelSnapshot(request.params)
        case "debug.panel_snapshot.reset":
            return debugPanelSnapshotReset(request.params)
        case "debug.window.screenshot":
            return debugScreenshot(request.params)
        case "debug.canvas.command_scroll_hint":
            return debugCanvasCommandScrollHint(request.params)
        default:
            return nil
        }
#else
        return nil
#endif
    }
}

#if DEBUG
extension ControlCommandCoordinator {
    /// The deterministic v1-style response used when the seam is unwired
    /// (`context == nil`). Unreachable in practice — the composition owner
    /// wires the context during its own init — but keeps the v1-forwarding
    /// bodies total: it fails both the `== "OK"` and `hasPrefix("OK ")`
    /// checks, surfacing as the legacy `internal_error` path.
    static let debugContextUnavailableResponse = "ERROR: control context unavailable"

    /// The debug-domain view of the seam. Once the integrator adds
    /// ``ControlDebugContext`` to the ``ControlCommandContext`` umbrella this
    /// cast is statically guaranteed (and may be simplified to `context`);
    /// until then it lets the domain build standalone without touching the
    /// integrator-owned umbrella file.
    var debugContext: (any ControlDebugContext)? {
        context as? any ControlDebugContext
    }

    // MARK: - debug.canvas.command_scroll_hint

    /// `debug.canvas.command_scroll_hint` — show the canvas scroll hint toast
    /// through the same canvas action path used by the Debug menu.
    func debugCanvasCommandScrollHint(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        let resolution = debugContext?.controlDebugShowCanvasCommandScrollHint(routing: routing)
            ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - debug.session_snapshot_benchmark

    /// `debug.session_snapshot_benchmark` — run the DEBUG snapshot benchmark.
    func debugSessionSnapshotBenchmark(_ params: [String: JSONValue]) -> ControlCallResult {
        let includeScrollback = bool(params, "include_scrollback")
            ?? bool(params, "scrollback")
            ?? false
        let persist = bool(params, "persist") ?? true
        guard let payload = debugContext?.controlDebugSessionSnapshotBenchmark(
            includeScrollback: includeScrollback,
            persist: persist
        ) else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }

    /// `debug.session_snapshot_seed_scrollback` — seed synthetic scrollback.
    func debugSessionSnapshotSeedScrollback(_ params: [String: JSONValue]) -> ControlCallResult {
        let charactersPerTerminal = int(params, "characters_per_terminal")
            ?? int(params, "chars_per_terminal")
            ?? 0
        guard let payload = debugContext?.controlDebugSessionSnapshotSeedScrollback(
            charactersPerTerminal: charactersPerTerminal
        ) else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }

    // MARK: - debug.shortcut.*

    /// `debug.shortcut.set` — bind a shortcut via the shared v1 body.
    func debugShortcutSet(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let name = string(params, "name"),
              let combo = string(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing name/combo", data: nil)
        }
        let resp = debugContext?.controlDebugSetShortcut(arguments: "\(name) \(combo)")
            ?? Self.debugContextUnavailableResponse
        return resp == "OK"
            ? .ok(.object([:]))
            : .err(code: "internal_error", message: resp, data: nil)
    }

    /// `debug.shortcut.simulate` — simulate a shortcut via the shared v1 body.
    func debugShortcutSimulate(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let combo = string(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing combo", data: nil)
        }
        let resp = debugContext?.controlDebugSimulateShortcut(combo: combo)
            ?? Self.debugContextUnavailableResponse
        return resp == "OK"
            ? .ok(.object([:]))
            : .err(code: "internal_error", message: resp, data: nil)
    }

    // MARK: - debug.type

    /// `debug.type` — insert text at the key window's first responder.
    func debugType(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy `params["text"] as? String`: raw, untrimmed; empty allowed.
        guard let text = rawString(params, "text") else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        switch debugContext?.controlDebugTypeText(text) {
        case .noWindow:
            return .err(code: "not_found", message: "No window", data: nil)
        case .noFirstResponder:
            return .err(code: "not_found", message: "No first responder", data: nil)
        case .inserted:
            return .ok(.object([:]))
        case nil:
            // The legacy body's initial (unreachable) value, kept for the
            // equally unreachable unwired-context case.
            return .err(code: "internal_error", message: "No window", data: nil)
        }
    }

    // MARK: - debug.textbox.*

    /// `debug.textbox.inline_fixture` — install the inline text-box fixture.
    func debugTextBoxInlineFixture(_ params: [String: JSONValue]) -> ControlCallResult {
        guard debugContext?.controlDebugTabManagerAvailable() == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let rawPathValue = rawString(params, "path")
        let rawPath = rawPathValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawPathValue, rawPathValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .err(code: "invalid_params", message: "path cannot be empty", data: nil)
        }
        let hasAttachment = rawPath?.isEmpty == false
        let beforeText = rawString(params, "before_text") ?? (hasAttachment ? "hello " : "")
        let afterText = rawString(params, "after_text") ?? (hasAttachment ? "world" : "")
        let rawSurfaceID = rawString(params, "surface_id")
        let target = rawSurfaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawSurfaceID,
           rawSurfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .err(code: "invalid_params", message: "surface_id cannot be empty", data: nil)
        }

        guard let snapshot = debugContext?.controlDebugTextBoxInlineFixture(
            target: target,
            path: rawPath,
            beforeText: beforeText,
            afterText: afterText
        ) else {
            return .err(code: "not_found", message: "Terminal panel not found", data: nil)
        }
        return .ok(.object([
            "surface_id": .string(snapshot.surfaceID.uuidString),
            "surface_ref": ref(.surface, snapshot.surfaceID),
            "path": .string(snapshot.path),
            "text_box_active": .bool(snapshot.isTextBoxActive),
            "has_text_view": .bool(snapshot.hasTextView),
            "text_view_has_window": .bool(snapshot.textViewHasWindow),
            "text_view_matches_panel_window": .bool(snapshot.textViewMatchesPanelWindow),
            "panel_text": .string(snapshot.panelText),
            "panel_attachment_count": .int(Int64(snapshot.panelAttachmentCount)),
            "text_view_text": .string(snapshot.textViewText),
            "text_view_attachment_count": .int(Int64(snapshot.textViewAttachmentCount)),
        ]))
    }

    /// `debug.textbox.interact` — drive one scripted text-box interaction.
    func debugTextBoxInteract(_ params: [String: JSONValue]) -> ControlCallResult {
        guard debugContext?.controlDebugTabManagerAvailable() == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        // Legacy re-trimmed and re-checked `v2String`'s output; `string` already
        // yields a trimmed non-empty value, so the acceptance is identical.
        guard let action = string(params, "action") else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }
        let rawSurfaceID = rawString(params, "surface_id")
        let target = rawSurfaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawSurfaceID,
           rawSurfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .err(code: "invalid_params", message: "surface_id cannot be empty", data: nil)
        }

        guard let interaction = debugContext?.controlDebugTextBoxInteract(target: target, action: action) else {
            return .err(code: "not_found", message: "Terminal text box not found", data: nil)
        }
        return .ok(.object([
            "surface_id": .string(interaction.surfaceID.uuidString),
            "surface_ref": ref(.surface, interaction.surfaceID),
            "action": .string(action),
            "state": interaction.state,
        ]))
    }

    // MARK: - debug.app.activate

    /// `debug.app.activate` — activate the app via the shared v1 body.
    func debugActivateApp() -> ControlCallResult {
        let resp = debugContext?.controlDebugActivateApp() ?? Self.debugContextUnavailableResponse
        return resp == "OK"
            ? .ok(.object([:]))
            : .err(code: "internal_error", message: resp, data: nil)
    }

    /// `debug.workspace_todo.checklist_add_field` — request the selected workspace's checklist add field.
    func debugWorkspaceTodoChecklistAddField() -> ControlCallResult {
        guard let debugContext else { return .err(code: "unavailable", message: "Control debug context unavailable", data: nil) }
        guard let workspaceID = debugContext.controlDebugRequestWorkspaceTodoChecklistAddField() else {
            return .err(code: "not_found", message: "No selected workspace", data: nil)
        }
        return .ok(.object(["workspace_id": .string(workspaceID.uuidString), "workspace_ref": ref(.workspace, workspaceID), "requested": .bool(true)]))
    }

    // MARK: - debug.command_palette.* (event posts)

    /// The shared body of the four palette-notification commands (`toggle`,
    /// `rename_tab.open`, `rename_input.interact`,
    /// `rename_input.delete_backward`): identical param shape, identical
    /// `not_found` payload, differing only in the posted notification.
    func debugCommandPaletteEvent(
        _ event: ControlDebugCommandPaletteEvent,
        _ params: [String: JSONValue]
    ) -> ControlCallResult {
        let requestedWindowID = uuid(params, "window_id")
        let posted = debugContext?.controlDebugPostCommandPaletteEvent(event, windowID: requestedWindowID) ?? false
        if let requestedWindowID, !posted {
            return .err(code: "not_found", message: "Window not found", data: .object([
                "window_id": .string(requestedWindowID.uuidString),
                "window_ref": ref(.window, requestedWindowID),
            ]))
        }
        return .ok(.object([:]))
    }

    // MARK: - debug.command_palette.* (reads)

    /// `debug.command_palette.visible` — palette visibility in a window.
    func debugCommandPaletteVisible(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let windowID = uuid(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let visible = debugContext?.controlDebugCommandPaletteVisible(windowID: windowID) ?? false
        return .ok(.object([
            "window_id": .string(windowID.uuidString),
            "window_ref": ref(.window, windowID),
            "visible": .bool(visible),
        ]))
    }

    /// `debug.command_palette.selection` — palette visibility + selected row.
    func debugCommandPaletteSelection(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let windowID = uuid(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let visible = debugContext?.controlDebugCommandPaletteVisible(windowID: windowID) ?? false
        let selectedIndex = debugContext?.controlDebugCommandPaletteSelectionIndex(windowID: windowID) ?? 0
        return .ok(.object([
            "window_id": .string(windowID.uuidString),
            "window_ref": ref(.window, windowID),
            "visible": .bool(visible),
            "selected_index": .int(Int64(max(0, selectedIndex))),
        ]))
    }

    /// `debug.command_palette.results` — palette query/mode/result rows.
    func debugCommandPaletteResults(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let windowID = uuid(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        // Legacy `params["limit"] as? Int` (NSNumber exact-integer semantics).
        let requestedLimit = legacyExactInt(params["limit"])
        let limit = max(1, min(100, requestedLimit ?? 20))

        let visible = debugContext?.controlDebugCommandPaletteVisible(windowID: windowID) ?? false
        let selectedIndex = debugContext?.controlDebugCommandPaletteSelectionIndex(windowID: windowID) ?? 0
        let snapshot = debugContext?.controlDebugCommandPaletteSnapshot(windowID: windowID) ?? .empty

        let rows: [JSONValue] = Array(snapshot.results.prefix(limit)).map { row in
            .object([
                "command_id": .string(row.commandID),
                "title": .string(row.title),
                "shortcut_hint": orNull(row.shortcutHint),
                "trailing_label": orNull(row.trailingLabel),
                "score": .int(Int64(row.score)),
            ])
        }

        return .ok(.object([
            "window_id": .string(windowID.uuidString),
            "window_ref": ref(.window, windowID),
            "visible": .bool(visible),
            "selected_index": .int(Int64(max(0, selectedIndex))),
            "query": .string(snapshot.query),
            "mode": .string(snapshot.mode),
            "results": .array(rows),
        ]))
    }

    /// `debug.command_palette.rename_input.selection` — field-editor selection.
    func debugCommandPaletteRenameInputSelection(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let windowID = uuid(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        // An unwired context reads as `inactive` — the legacy body's initial
        // `focused: false` payload, which survived when nothing ran.
        let resolution = debugContext?.controlDebugCommandPaletteRenameInputSelection(windowID: windowID)
            ?? .inactive
        switch resolution {
        case .windowNotFound:
            return .err(code: "not_found", message: "Window not found", data: .object([
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        case .inactive:
            return .ok(.object([
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
                "focused": .bool(false),
                "selection_location": .int(0),
                "selection_length": .int(0),
                "text_length": .int(0),
            ]))
        case .active(let location, let length, let textLength):
            return .ok(.object([
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
                "focused": .bool(true),
                "selection_location": .int(Int64(max(0, location))),
                "selection_length": .int(Int64(max(0, length))),
                "text_length": .int(Int64(max(0, textLength))),
            ]))
        }
    }

    /// `debug.command_palette.rename_input.select_all` — read (and optionally
    /// write) the select-all-on-focus setting.
    func debugCommandPaletteRenameInputSelectAll(_ params: [String: JSONValue]) -> ControlCallResult {
        var newValue: Bool?
        if let rawEnabled = params["enabled"] {
            // Legacy `rawEnabled as? Bool` on the bridged NSNumber: booleans
            // pass, 0/1 numbers pass, everything else errors.
            guard let enabled = legacyExactBool(rawEnabled) else {
                return .err(
                    code: "invalid_params",
                    message: "enabled must be a bool",
                    data: .object(["enabled": rawEnabled])
                )
            }
            newValue = enabled
        }
        let enabled = debugContext?.controlDebugCommandPaletteRenameSelectAll(updating: newValue) ?? false
        return .ok(.object([
            "enabled": .bool(enabled)
        ]))
    }

    // MARK: - Legacy NSNumber-cast twins

    /// The typed twin of the legacy `value as? Int` on a JSON-bridged
    /// `NSNumber`: exact integers pass, booleans bridge to `0`/`1`, fractional
    /// or non-numeric values fail. (Distinct from `strictIntValue`, which
    /// rejects booleans and accepts numeric strings.)
    func legacyExactInt(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let v):
            return Int(exactly: v)
        case .double(let v):
            return Int(exactly: v)
        case .bool(let v):
            return v ? 1 : 0
        default:
            return nil
        }
    }

    /// The typed twin of the legacy `value as? Bool` on a JSON-bridged
    /// `NSNumber`: booleans pass, and exactly-`0`/`1` numbers bridge to
    /// `false`/`true` (Foundation's `Bool(exactly:)` semantics).
    func legacyExactBool(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let v):
            return v
        case .int(0):
            return false
        case .int(1):
            return true
        case .double(let v) where v == 0:
            return false
        case .double(let v) where v == 1:
            return true
        default:
            return nil
        }
    }
}
#endif
