internal import Foundation

/// The system/misc domain (`system.identify`, `system.tree`, `auth.login`,
/// `session.restore_previous`, `settings.open`, `feedback.open`,
/// `extension.sidebar.snapshot`, `workspace.action`, `surface.action` /
/// `tab.action`, `surface.drag_to_split` / `surface.split_off`, and the
/// DEBUG-only `mobile.dev_stack_auth.configure`), lifted byte-faithfully from
/// the former `TerminalController` bodies.
extension ControlCommandCoordinator {
    /// The system-domain slice of the seam. A typed view of ``context`` so the
    /// domain compiles independently of the umbrella's inheritance list (the
    /// integrator adds ``ControlSystemContext`` to ``ControlCommandContext``;
    /// the conformer is the same object either way).
    var systemContext: (any ControlSystemContext)? {
        context as? any ControlSystemContext
    }

    /// Dispatches the system-domain methods this coordinator owns; returns
    /// `nil` for anything else so the core `handle(_:)` can fall through.
    func handleSystem(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "system.identify":
            return systemIdentify(request.params)
        case "system.tree":
            return systemTree(request.params)
        case "auth.login":
            return authLogin()
        case "session.restore_previous":
            return sessionRestorePrevious()
        case "settings.open":
            return settingsOpen(request.params)
        case "feedback.open":
            return feedbackOpen(request.params)
        case "extension.sidebar.snapshot":
            return extensionSidebarSnapshot(request.params)
        case "workspace.action":
            return workspaceAction(request.params)
        case "surface.action", "tab.action":
            return tabAction(request.params)
        case "surface.drag_to_split", "surface.split_off":
            return surfaceSplitOff(request.params)
#if DEBUG
        case "mobile.dev_stack_auth.configure":
            return mobileDevStackAuthConfigure(request.params)
#endif
        default:
            return nil
        }
    }

    /// `system.identify` — the shared identify payload (always ok).
    func systemIdentify(_ params: [String: JSONValue]) -> ControlCallResult {
        .ok(systemContext?.controlSystemIdentify(params: params) ?? .object([:]))
    }

    /// `system.tree` — the window/workspace/pane/surface tree snapshot.
    func systemTree(_ params: [String: JSONValue]) -> ControlCallResult {
        let workspaceFilter = uuid(params, "workspace_id")
        if params["workspace_id"] != nil && workspaceFilter == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        switch systemWindowRouting(params) {
        case .invalid(let error):
            return error
        case .routed(let routing):
            let resolution = systemContext?.controlSystemTreeWindows(
                requestedWindowID: routing.requestedWindowID,
                includeAllWindows: routing.includeAllWindows,
                focusedWindowID: routing.focusedWindowID,
                workspaceFilter: workspaceFilter
            ) ?? ControlSystemTreeResolution(
                windowFound: routing.requestedWindowID == nil,
                workspaceFound: workspaceFilter == nil,
                windows: []
            )

            if let requestedWindowID = routing.requestedWindowID, !resolution.windowFound {
                return systemWindowNotFound(params, windowID: requestedWindowID)
            }
            if let workspaceFilter, !resolution.workspaceFound {
                return .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: .object([
                        "workspace_id": .string(workspaceFilter.uuidString),
                        "workspace_ref": ref(.workspace, workspaceFilter),
                    ])
                )
            }

            return .ok(.object([
                "active": routing.focused.isEmpty ? .null : .object(routing.focused),
                "caller": routing.caller.isEmpty ? .null : .object(routing.caller),
                "windows": .array(resolution.windows.map(systemTreeWindowPayload)),
            ]))
        }
    }

    // MARK: - Tree payload shaping

    /// The `system.tree` window node payload (the legacy `v2TreeWindowNode`).
    private func systemTreeWindowPayload(_ node: ControlSystemTreeWindowNode) -> JSONValue {
        .object([
            "id": .string(node.summary.windowID.uuidString),
            "ref": ref(.window, node.summary.windowID),
            "index": .int(Int64(node.index)),
            "key": .bool(node.summary.isKeyWindow),
            "visible": .bool(node.summary.isVisible),
            "workspace_count": .int(Int64(node.workspaces.count)),
            "selected_workspace_id": orNull(node.summary.selectedWorkspaceID?.uuidString),
            "selected_workspace_ref": ref(.workspace, node.summary.selectedWorkspaceID),
            "workspaces": .array(node.workspaces.map(systemTreeWorkspacePayload)),
        ])
    }

    /// The `system.tree` workspace node payload (the legacy
    /// `v2TreeWorkspaceNode`).
    private func systemTreeWorkspacePayload(_ node: ControlSystemTreeWorkspaceNode) -> JSONValue {
        .object([
            "id": .string(node.workspaceID.uuidString),
            "ref": ref(.workspace, node.workspaceID),
            "index": .int(Int64(node.index)),
            "title": .string(node.title),
            "description": orNull(node.description),
            "selected": .bool(node.isSelected),
            "pinned": .bool(node.isPinned),
            "panes": .array(node.panes.map(systemTreePanePayload)),
        ])
    }

    /// The `system.tree` pane node payload.
    private func systemTreePanePayload(_ node: ControlSystemTreePaneNode) -> JSONValue {
        .object([
            "id": .string(node.paneID.uuidString),
            "ref": ref(.pane, node.paneID),
            "index": .int(Int64(node.index)),
            "focused": .bool(node.isFocused),
            "surface_ids": .array(node.surfaceIDs.map { .string($0.uuidString) }),
            "surface_refs": .array(node.surfaceIDs.map { ref(.surface, $0) }),
            "selected_surface_id": orNull(node.selectedSurfaceID?.uuidString),
            "selected_surface_ref": ref(.surface, node.selectedSurfaceID),
            "surface_count": .int(Int64(node.surfaceIDs.count)),
            "surfaces": .array(node.surfaces.map(systemTreeSurfacePayload)),
        ])
    }

    /// The `system.tree` surface node payload (browser surfaces emit their URL
    /// string — empty when absent — and non-browsers emit JSON `null`).
    private func systemTreeSurfacePayload(_ node: ControlSystemTreeSurfaceNode) -> JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(node.surfaceID.uuidString),
            "ref": ref(.surface, node.surfaceID),
            "index": .int(Int64(node.index)),
            "type": .string(node.typeRawValue),
            "title": .string(node.title),
            "focused": .bool(node.isFocused),
            "selected": .bool(node.isSelected),
            "selected_in_pane": node.selectedInPane.map { JSONValue.bool($0) } ?? .null,
            "pane_id": orNull(node.paneID?.uuidString),
            "pane_ref": ref(.pane, node.paneID),
            "index_in_pane": node.indexInPane.map { JSONValue.int(Int64($0)) } ?? .null,
            "tty": orNull(node.tty),
        ]
        item["url"] = node.isBrowser ? .string(node.url ?? "") : .null
        return .object(item)
    }
}
