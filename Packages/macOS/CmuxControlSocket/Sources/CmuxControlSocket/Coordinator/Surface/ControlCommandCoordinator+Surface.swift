internal import Foundation

/// The surface domain (`surface.*` plus `debug.terminals`), lifted byte-faithfully
/// from the former `TerminalController.v2Surface*` / `v2DebugTerminals` bodies.
/// Each payload is built directly as a ``JSONValue``; the encoded wire bytes match.
/// The coordinator owns param parsing and ref minting; the app-coupled work runs
/// behind the ``ControlSurfaceContext`` seam.
///
/// This file carries the dispatch plus the read/lifecycle methods; the remaining
/// methods live in `+Surface2.swift` / `+Surface3.swift` (500-line budget).
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the surface domain, returning the
    /// typed result; returns `nil` otherwise so the caller can fall through. The
    /// integrator calls this from the core `handle`.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a surface method.
    func handleSurface(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "surface.list":
            return surfaceList(request.params)
        case "surface.current":
            return surfaceCurrent(request.params)
        case "surface.focus":
            return surfaceFocus(request.params)
        case "surface.split":
            return surfaceSplit(request.params)
        case "surface.respawn":
            return surfaceRespawn(request.params)
        case "surface.create":
            return surfaceCreate(request.params)
        case "surface.close":
            return surfaceClose(request.params)
        case "surface.move":
            return surfaceMove(request.params)
        case "surface.reorder":
            return surfaceReorder(request.params)
        case "surface.refresh":
            return surfaceRefresh(request.params)
        case "surface.health":
            return surfaceHealth(request.params)
        case "surface.resume.set":
            return surfaceResumeSet(request.params)
        case "surface.resume.get":
            return surfaceResumeGet(request.params)
        case "surface.resume.clear":
            return surfaceResumeClear(request.params)
        case "surface.send_text":
            return surfaceSendText(request.params)
        case "surface.send_key":
            return surfaceSendKey(request.params)
        case "surface.report_tty": return surfaceReportTTY(request.params)
        case "surface.report_pwd": return surfaceReportPWD(request.params)
        case "surface.report_shell_state":
            return surfaceReportShellState(request.params)
        case "surface.ports_kick":
            return surfacePortsKick(request.params)
        case "surface.clear_history":
            return surfaceClearHistory(request.params)
        // `surface.read_text` runs on the socket-worker lane (issue #5757),
        // dispatched app-side, not through this @MainActor coordinator.
        case "surface.trigger_flash":
            return surfaceTriggerFlash(request.params)
        case "debug.terminals":
            return debugTerminals(request.params)
        default:
            return nil
        }
    }

    /// The shared "cmux window is not available" message (legacy
    /// `Self.v2WindowUnavailableMessage`).
    static let surfaceWindowUnavailableMessage =
        "cmux window is not available. Reopen the window and try again."

    // MARK: - list

    /// `surface.list` — the resolved workspace's surfaces.
    func surfaceList(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let snapshot = context?.controlSurfaceList(routing: routing) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }

        let surfaces: [JSONValue] = snapshot.surfaces.enumerated().map { index, surface in
            var item: [String: JSONValue] = [
                "id": .string(surface.surfaceID.uuidString),
                "ref": ref(.surface, surface.surfaceID),
                "index": .int(Int64(index)),
                "type": .string(surface.typeRawValue),
                "title": .string(surface.title),
                "focused": .bool(surface.isFocused),
                "pane_id": orNull(surface.paneID?.uuidString),
                "pane_ref": ref(.pane, surface.paneID),
                "index_in_pane": surface.indexInPane.map { .int(Int64($0)) } ?? .null,
                "selected_in_pane": surface.selectedInPane.map { .bool($0) } ?? .null,
            ]
            if let dev = surface.developerToolsVisible {
                item["developer_tools_visible"] = .bool(dev)
            }
            if surface.isTerminal {
                item["requested_working_directory"] = orNull(surface.requestedWorkingDirectory)
                item["initial_command"] = orNull(surface.initialCommand)
                item["tmux_start_command"] = orNull(surface.tmuxStartCommand)
                item["resume_binding"] = surfaceResumeBindingPayload(surface.resumeBinding)
            }
            return .object(item)
        }

        return .ok(.object([
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
            "surfaces": .array(surfaces),
            "window_id": orNull(snapshot.windowID?.uuidString),
            "window_ref": ref(.window, snapshot.windowID),
        ]))
    }

    // MARK: - current

    /// `surface.current` — the resolved workspace's current surface.
    func surfaceCurrent(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let snapshot = context?.controlSurfaceCurrent(routing: routing) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(.object([
            "window_id": orNull(snapshot.windowID?.uuidString),
            "window_ref": ref(.window, snapshot.windowID),
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
            "pane_id": orNull(snapshot.paneID?.uuidString),
            "pane_ref": ref(.pane, snapshot.paneID),
            "surface_id": orNull(snapshot.surfaceID?.uuidString),
            "surface_ref": ref(.surface, snapshot.surfaceID),
            "surface_type": orNull(snapshot.surfaceTypeRawValue),
        ]))
    }

    // MARK: - health

    /// `surface.health` — render health for the resolved workspace's surfaces.
    func surfaceHealth(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let snapshot = context?.controlSurfaceHealth(routing: routing) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        let items: [JSONValue] = snapshot.surfaces.enumerated().map { index, entry in
            .object([
                "index": .int(Int64(index)),
                "id": .string(entry.surfaceID.uuidString),
                "ref": ref(.surface, entry.surfaceID),
                "type": .string(entry.typeRawValue),
                "in_window": entry.inWindow.map { .bool($0) } ?? .null,
            ])
        }
        return .ok(.object([
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
            "surfaces": .array(items),
            "window_id": orNull(snapshot.windowID?.uuidString),
            "window_ref": ref(.window, snapshot.windowID),
        ]))
    }

    // MARK: - focus

    /// `surface.focus` — focus a surface in the resolved workspace.
    func surfaceFocus(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let resolution = context?.controlSurfaceFocus(routing: routing, surfaceID: surfaceID)
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .surfaceNotFound(let id):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .focused(let windowID, let workspaceID, let focusedSurfaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(focusedSurfaceID.uuidString),
                "surface_ref": ref(.surface, focusedSurfaceID),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - split

    /// `surface.split` — split a surface into a new pane.
    func surfaceSplit(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        // Token set mirrors the app's `parseSplitDirection`; validating it here
        // preserves the legacy error ORDER (direction → agent-session → divider).
        guard let directionRaw = string(params, "direction"),
              ["left", "l", "right", "r", "up", "u", "down", "d"].contains(directionRaw.lowercased()) else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid direction (left|right|up|down)",
                data: nil
            )
        }
        // Legacy rejected agent-session BEFORE divider validation (token match
        // mirrors the app's `v2PanelType` normalized-token mapping).
        if let typeRaw = string(params, "type"), normalizedToken(typeRaw) == "agentsession" {
            return .err(
                code: "invalid_params",
                message: "agent-session is only supported by surface.create",
                data: .object(["type": .string("agentSession")])
            )
        }
        let parsedDivider = initialDividerPosition(params)
        if let error = parsedDivider.error { return error }

        let inputs = ControlSurfaceSplitInputs(
            directionRaw: directionRaw,
            typeRaw: string(params, "type"),
            urlRaw: string(params, "url"),
            requestedSourceSurfaceID: uuid(params, "surface_id"),
            workingDirectory: optionalTrimmedRawString(params, "working_directory"),
            initialCommand: optionalTrimmedRawString(params, "initial_command"),
            tmuxStartCommand: optionalTrimmedRawString(params, "tmux_start_command"),
            remotePTYSessionID: optionalTrimmedRawString(params, "remote_pty_session_id"),
            startupEnvironment: trimmedStringMap(params, keys: ["startup_environment", "initial_env"]),
            clientUnsupportedRemoteTmuxOptions: stringArray(params, "remote_tmux_unsupported_options") ?? [],
            requestedFocus: bool(params, "focus") ?? false,
            initialDividerPosition: parsedDivider.value
        )

        let resolution = context?.controlSurfaceSplit(routing: routing, inputs: inputs)
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .invalidDirection:
            // Drift-safety net: the coordinator pre-validates the same token set,
            // so this only fires if the app's parseSplitDirection ever diverges —
            // and then it still emits the legacy error.
            return .err(
                code: "invalid_params",
                message: "Missing or invalid direction (left|right|up|down)",
                data: nil
            )
        case .agentSessionRejected(let typeRawValue):
            return .err(
                code: "invalid_params",
                message: "agent-session is only supported by surface.create",
                data: .object(["type": .string(typeRawValue)])
            )
        case .browserDisabled(let outcome):
            return browserDisabledResult(outcome)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .requestedSurfaceNotFound(let id):
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface", data: nil)
        case .createFailed:
            return .err(code: "internal_error", message: "Failed to create split", data: nil)
        case .mirrorUnsupportedOptions(let unsupported):
            return mirrorUnsupportedOptionsResult(unsupported)
        case .routedToRemote(let windowID, let workspaceID, let typeRawValue):
            return remoteRoutedCreationResult(
                windowID: windowID,
                workspaceID: workspaceID,
                typeRawValue: typeRawValue
            )
        case .created(let windowID, let workspaceID, let paneID, let surfaceID, let typeRawValue):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": orNull(paneID?.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "type": orNull(typeRawValue),
            ]))
        }
    }

    // MARK: - respawn

    /// `surface.respawn` — respawn a terminal surface.
    func surfaceRespawn(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard let strings = context?.controlSurfaceRespawnStrings() else {
            // No seam wired; the focused-branch fallback would also be unavailable.
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let command = optionalTrimmedRawString(params, "command")
            ?? optionalTrimmedRawString(params, "initial_command")
            ?? "exec ${SHELL:-/bin/zsh} -l"
        let tmuxStartCommand = optionalTrimmedRawString(params, "tmux_start_command") ?? command
        let workingDirectory = optionalTrimmedRawString(params, "working_directory")

        let hasFocusParam = hasNonNull(params, "focus")
        if hasFocusParam, bool(params, "focus") == nil {
            return .err(code: "invalid_params", message: strings.invalidFocus, data: nil)
        }

        let inputs = ControlSurfaceRespawnInputs(
            command: command,
            tmuxStartCommand: tmuxStartCommand,
            workingDirectory: workingDirectory,
            hasSurfaceIDParam: hasNonNull(params, "surface_id"),
            requestedSurfaceID: uuid(params, "surface_id"),
            hasFocusParam: hasFocusParam,
            requestedFocus: bool(params, "focus") ?? false
        )

        let resolution = context?.controlSurfaceRespawn(routing: routing, inputs: inputs)
        guard let resolution else {
            return .err(code: "internal_error", message: strings.failed, data: nil)
        }
        switch resolution {
        case .surfaceNotFoundForID(let id):
            return .err(
                code: "not_found",
                message: strings.surfaceNotFoundForID,
                data: id.map { .object(["surface_id": .string($0.uuidString)]) }
            )
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: strings.tabManagerUnavailable, data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: strings.workspaceNotFound, data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: strings.noFocusedSurface, data: nil)
        case .surfaceNotTerminal(let id):
            return .err(
                code: "invalid_params",
                message: strings.surfaceNotTerminal,
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .respawnFailed(let id):
            return .err(
                code: "internal_error",
                message: strings.failed,
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .respawned(let windowID, let workspaceID, let surfaceID, let typeRawValue):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "type": .string(typeRawValue),
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
            ]))
        }
    }

    // MARK: - create

    /// `surface.create` — create a surface in a pane.
    func surfaceCreate(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let inputs = ControlSurfaceCreateInputs(
            typeRaw: string(params, "type"),
            providerRaw: string(params, "provider_id") ?? string(params, "provider"),
            rendererRaw: string(params, "renderer_kind") ?? string(params, "renderer"),
            urlRaw: string(params, "url"),
            workingDirectory: optionalTrimmedRawString(params, "working_directory"),
            initialCommand: optionalTrimmedRawString(params, "initial_command"),
            tmuxStartCommand: optionalTrimmedRawString(params, "tmux_start_command"),
            remotePTYSessionID: optionalTrimmedRawString(params, "remote_pty_session_id"),
            startupEnvironment: trimmedStringMap(params, keys: ["startup_environment", "initial_env"]),
            requestedPaneID: uuid(params, "pane_id"),
            requestedFocus: bool(params, "focus") ?? false,
            placementRaw: string(params, "placement")
        )

        let resolution = context?.controlSurfaceCreate(routing: routing, inputs: inputs)
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .invalidProvider(let rawValue):
            return .err(
                code: "invalid_params",
                message: "Invalid provider (codex|claude|opencode)",
                data: .object(["provider": .string(rawValue)])
            )
        case .invalidRenderer(let rawValue):
            return .err(
                code: "invalid_params",
                message: "Invalid renderer (react|solid)",
                data: .object(["renderer": .string(rawValue)])
            )
        case .invalidPlacement(let rawValue):
            return .err(code: "invalid_params", message: "placement must be one of: workspace, dock", data: .object(["placement": .string(rawValue)]))
        case .dockUnsupportedType(let typeRawValue, let message):
            return .err(code: "invalid_params", message: message, data: .object(["type": .string(typeRawValue)]))
        case .dockUnavailable(let message):
            return .err(code: "invalid_params", message: message, data: .object(["placement": .string("dock")]))
        case .browserDisabled(let outcome):
            return browserDisabledResult(outcome)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .paneNotFound:
            return .err(code: "not_found", message: "Pane not found", data: nil)
        case .createFailed:
            return .err(code: "internal_error", message: "Failed to create surface", data: nil)
        case .mirrorUnsupportedOptions(let unsupported):
            return mirrorUnsupportedOptionsResult(unsupported)
        case .routedToRemote(let windowID, let workspaceID, let typeRawValue):
            return remoteRoutedCreationResult(
                windowID: windowID,
                workspaceID: workspaceID,
                typeRawValue: typeRawValue
            )
        case .createdDock(let windowID, let workspaceID, let dockPaneID, let dockSurfaceID, let typeRawValue):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "placement": .string("dock"),
                "pane_id": .null,
                "pane_ref": .null,
                "surface_id": .null,
                "surface_ref": .null,
                "dock_pane_id": .string(dockPaneID.uuidString),
                "dock_surface_id": .string(dockSurfaceID.uuidString),
                "type": .string(typeRawValue),
            ]))
        case .created(let windowID, let workspaceID, let paneID, let surfaceID, let typeRawValue):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "type": .string(typeRawValue),
            ]))
        }
    }

    // MARK: - close

    /// `surface.close` — force-close a surface.
    func surfaceClose(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlSurfaceRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlSurfaceClose(routing: routing, surfaceID: uuid(params, "surface_id"))
            ?? .tabManagerUnavailable
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
        case .lastSurface:
            return .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
        case .closeFailed(let id):
            return .err(
                code: "internal_error",
                message: "Failed to close surface",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .closed(let windowID, let workspaceID, let surfaceID):
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

}
