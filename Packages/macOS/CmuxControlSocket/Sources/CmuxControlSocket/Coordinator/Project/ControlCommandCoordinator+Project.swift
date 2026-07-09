internal import Foundation

/// The project domain (`project.open` and the `project.set_*` /
/// `project.get_state` debug RPCs), lifted byte-faithfully from the former
/// `TerminalController.v2Project*` bodies.
extension ControlCommandCoordinator {
    /// The project-domain slice of the seam. A typed view of ``context`` so
    /// the domain compiles independently of the umbrella's inheritance list
    /// (the integrator adds ``ControlProjectContext`` to
    /// ``ControlCommandContext``; the conformer is the same object either
    /// way).
    var projectContext: (any ControlProjectContext)? {
        context
    }

    /// Dispatches the project-domain methods this coordinator owns; returns
    /// `nil` for anything else so the core `handle(_:)` can fall through.
    func handleProject(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "project.open":
            return projectOpen(request.params)
        case "project.set_tab":
            return projectSetTab(request.params)
        case "project.set_scheme":
            return projectSetScheme(request.params)
        case "project.set_configuration":
            return projectSetConfiguration(request.params)
        case "project.set_selected_target":
            return projectSetSelectedTarget(request.params)
        case "project.set_selected_file":
            return projectSetSelectedFile(request.params)
        case "project.set_settings_filter":
            return projectSetSettingsFilter(request.params)
        case "project.get_state":
            return projectGetState(request.params)
        case "markdown.open":
            return markdownOpen(request.params)
        case "file.open":
            return fileOpen(request.params)
        default:
            return nil
        }
    }

    /// `project.open` — open a project panel in the focused pane.
    func projectOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard projectContext?.controlProjectRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawPath = string(params, "path") else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved: String
        if expanded.hasPrefix("/") {
            resolved = expanded
        } else {
            resolved = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        }
        guard FileManager.default.fileExists(atPath: resolved) else {
            return .err(code: "not_found", message: "Project not found at \(resolved)", data: nil)
        }

        let resolution = projectContext?.controlProjectOpen(
            routing: routing,
            path: resolved,
            requestedFocus: bool(params, "focus") ?? true
        ) ?? .createFailed
        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noFocusedPane:
            return .err(code: "not_found", message: "No focused pane to open project in", data: nil)
        case .createFailed:
            return .err(code: "internal_error", message: "Failed to create project panel", data: nil)
        case .opened(let windowID, let workspaceID, let paneID, let surfaceID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "workspace_id": .string(workspaceID.uuidString),
                "pane_id": orNull(paneID?.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "path": .string(resolved),
            ]))
        }
    }

    /// `project.set_tab` — switch the project panel's active tab.
    func projectSetTab(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = projectContext?.controlProjectSetTab(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id"),
            tabRaw: string(params, "tab")
        ) ?? .panelNotFound
        switch resolution {
        case .panelNotFound:
            return projectPanelNotFound()
        case .invalidTab:
            return .err(
                code: "invalid_params",
                message: "tab must be one of files|targets|buildSettings|schemes",
                data: nil
            )
        case .set(let tab):
            return .ok(.object(["tab": .string(tab)]))
        }
    }

    /// `project.set_scheme` — set the selected scheme.
    func projectSetScheme(_ params: [String: JSONValue]) -> ControlCallResult {
        let name = string(params, "name")
        let resolution = projectContext?.controlProjectSetScheme(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id"),
            name: name
        ) ?? .panelNotFound
        switch resolution {
        case .panelNotFound:
            return projectPanelNotFound()
        case .updated:
            return .ok(.object(["scheme": .string(name ?? "")]))
        }
    }

    /// `project.set_configuration` — set the selected configuration.
    func projectSetConfiguration(_ params: [String: JSONValue]) -> ControlCallResult {
        let name = string(params, "name")
        let resolution = projectContext?.controlProjectSetConfiguration(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id"),
            name: name
        ) ?? .panelNotFound
        switch resolution {
        case .panelNotFound:
            return projectPanelNotFound()
        case .updated:
            return .ok(.object(["configuration": .string(name ?? "")]))
        }
    }

    /// `project.set_selected_target` — select a target by display name.
    func projectSetSelectedTarget(_ params: [String: JSONValue]) -> ControlCallResult {
        let name = string(params, "name")
        let resolution = projectContext?.controlProjectSetSelectedTarget(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id"),
            name: name
        ) ?? .panelNotFound
        switch resolution {
        case .panelNotFound:
            return projectPanelNotFound()
        case .updated(let targetID):
            return .ok(.object([
                "target_name": .string(name ?? ""),
                "target_id": .string(targetID ?? ""),
            ]))
        }
    }

    /// `project.set_selected_file` — select a file in the project tree.
    func projectSetSelectedFile(_ params: [String: JSONValue]) -> ControlCallResult {
        let path = string(params, "path")
        let resolution = projectContext?.controlProjectSetSelectedFile(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id"),
            path: path
        ) ?? .panelNotFound
        switch resolution {
        case .panelNotFound:
            return projectPanelNotFound()
        case .updated:
            return .ok(.object(["selected_file": .string(path ?? "")]))
        }
    }

    /// `project.set_settings_filter` — set the build-settings filter text.
    func projectSetSettingsFilter(_ params: [String: JSONValue]) -> ControlCallResult {
        let text = string(params, "text") ?? ""
        let resolution = projectContext?.controlProjectSetSettingsFilter(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id"),
            text: text
        ) ?? .panelNotFound
        switch resolution {
        case .panelNotFound:
            return projectPanelNotFound()
        case .updated:
            return .ok(.object(["filter": .string(text)]))
        }
    }

    /// `project.get_state` — snapshot the project panel state.
    func projectGetState(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = projectContext?.controlProjectGetState(
            routing: routingSelectors(params),
            surfaceID: uuid(params, "surface_id")
        ) ?? .panelNotFound
        switch resolution {
        case .panelNotFound:
            return projectPanelNotFound()
        case .state(let snapshot):
            var payload: [String: JSONValue] = [
                "surface_id": .string(snapshot.surfaceID.uuidString),
                "project_url": .string(snapshot.projectURLPath),
                "active_tab": .string(snapshot.activeTabRawValue),
                "selected_scheme": .string(snapshot.selectedScheme),
                "selected_configuration": .string(snapshot.selectedConfiguration),
                "selected_target_id": .string(snapshot.selectedTargetID),
                "selected_file": .string(snapshot.selectedFile),
                "settings_filter": .string(snapshot.settingsFilter),
            ]
            switch snapshot.loadState {
            case .idle:
                payload["load_state"] = .string("idle")
            case .loading:
                payload["load_state"] = .string("loading")
            case .failed(let reason):
                payload["load_state"] = .string("failed")
                payload["load_error"] = .string(reason)
            case .loaded(let moduleCount, let module):
                payload["load_state"] = .string("loaded")
                payload["module_count"] = .int(Int64(moduleCount))
                if let module {
                    payload["module_name"] = .string(module.name)
                    payload["target_count"] = .int(Int64(module.targetCount))
                    payload["target_names"] = .array(module.targetNames.map { .string($0) })
                    payload["scheme_count"] = .int(Int64(module.schemeCount))
                    payload["scheme_names"] = .array(module.schemeNames.map { .string($0) })
                    payload["configuration_names"] = .array(module.configurationNames.map { .string($0) })
                    payload["root_group_children"] = .int(Int64(module.rootGroupChildren))
                }
            }
            return .ok(.object(payload))
        }
    }

    /// The shared `project.*` not-found error (the legacy
    /// `v2ResolveProjectPanel` failure).
    private func projectPanelNotFound() -> ControlCallResult {
        .err(code: "not_found", message: "Project surface not found", data: nil)
    }
}
