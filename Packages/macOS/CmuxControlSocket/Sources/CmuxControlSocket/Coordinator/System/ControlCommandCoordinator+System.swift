internal import Foundation

/// The system/misc domain (`system.ping`, `system.capabilities`,
/// `system.identify`, `system.tree`, `auth.login`,
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
        context
    }

    /// Dispatches the system-domain methods this coordinator owns; returns
    /// `nil` for anything else so the core `handle(_:)` can fall through.
    func handleSystem(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "system.ping":
            return systemPing()
        case "system.capabilities":
            return systemCapabilities()
        case "system.identify":
            // Worker-lane resolution reads (tranche D): the nonisolated bodies
            // are shared with the socket dispatcher's worker lane; from this
            // main-actor dispatch their hop collapses inline.
            return systemIdentify(request.params, context: context)
        case "system.tree":
            return systemTree(request.params, context: context)
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

    /// `system.ping` — the trivial `{"pong": true}` acknowledgement, built by
    /// the shared ``ControlSystemProbe`` (the same value the worker lane uses).
    func systemPing() -> ControlCallResult {
        ControlSystemProbe().ping()
    }

    /// `system.capabilities` — the protocol banner plus the live
    /// `socket_path` / `access_mode` and the sorted method catalog, built by the
    /// shared ``ControlSystemProbe`` over the seam's live server state.
    func systemCapabilities() -> ControlCallResult {
        ControlSystemProbe().capabilities(
            socketPath: systemContext?.controlSystemSocketPath() ?? "",
            accessModeRawValue: systemContext?.controlSystemAccessModeRawValue() ?? ""
        )
    }

    /// `system.identify` — the shared identify payload (always ok).
    ///
    /// Worker-lane resolution read (tranche D of issue #5757): the whole
    /// identify body — focused-window resolution, the caller-context
    /// validation, and its ref minting — runs inside ONE
    /// `controlResolveOnMain` hop (which refreshes known refs first), so the
    /// payload is the same single main-actor snapshot the main-lane dispatch
    /// produced; only the JSON encode leaves the main thread.
    nonisolated func systemIdentify(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let context else { return .ok(.object([:])) }
        return .ok(context.controlResolveOnMain { _ in
            self.identify(params: params)
        })
    }

    /// The `system.tree` hop outcome: either an error result fully resolved
    /// on the main actor (in the legacy evaluation order), or the Sendable
    /// tree plus the parallel ref tree minted in the payload's literal order.
    private enum SystemTreeHopOutcome: Sendable {
        case finished(ControlCallResult)
        case resolved(
            focused: [String: JSONValue],
            caller: [String: JSONValue],
            windows: [ControlSystemTreeWindowNode],
            refs: [SystemTreeWindowRefs]
        )
    }

    /// `system.tree` — the window/workspace/pane/surface tree snapshot.
    ///
    /// Worker-lane resolution read, the widest in this set: the
    /// workspace-filter parse (registry lookup), the window-routing parse
    /// (which resolves the caller identity through the identify seam), the
    /// tree walk witness, the legacy-ordered error selection, and the ref
    /// mint pass all take ONE `controlResolveOnMain` hop; the full
    /// tree-to-JSON mapping — the biggest encode win in this set — runs on
    /// the calling socket-worker thread over the Sendable nodes and
    /// pre-minted refs.
    nonisolated func systemTree(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        let outcome: SystemTreeHopOutcome
        if let context {
            outcome = context.controlResolveOnMain { seam in
                self.systemTreeHopBody(params, seam: seam)
            }
        } else if Thread.isMainThread {
            // Unwired seam: only the main-actor dispatch produces a nil
            // context (the socket worker lane always passes its live seam),
            // and the legacy body ran this flow inline on main — params still
            // parse, the routing still validates, and the walk resolves an
            // empty world. No known-ref refresh, exactly as before (the
            // main lane's refresh lives app-side, ahead of the dispatch).
            outcome = MainActor.assumeIsolated {
                self.systemTreeHopBody(params, seam: nil)
            }
        } else {
            // Unreachable today (a nil context never comes from the worker
            // lane). Fail loudly and distinctly — the generic `unavailable`
            // reply would make this drift indistinguishable from routine
            // TabManager unavailability (mirrors the worker lanes'
            // policy-listed-without-handler backstops).
            assertionFailure("system.tree dispatched off-main with a nil context seam")
            return .err(
                code: "internal_error",
                message: "system.tree dispatched off-main without a context seam",
                data: nil
            )
        }
        switch outcome {
        case .finished(let result):
            return result
        case let .resolved(focused, caller, windows, refs):
            return .ok(.object([
                "active": focused.isEmpty ? .null : .object(focused),
                "caller": caller.isEmpty ? .null : .object(caller),
                "windows": .array(zip(windows, refs).map { pair in systemTreeWindowPayload(pair.0, refs: pair.1) }),
            ]))
        }
    }

    /// The main-actor half of `system.tree`: workspace-filter parse, window
    /// routing (identify-derived), the tree walk witness, error selection in
    /// the legacy order, and the ref mint pass.
    private func systemTreeHopBody(
        _ params: [String: JSONValue],
        seam: (any ControlCommandContext)?
    ) -> SystemTreeHopOutcome {
        let workspaceFilter = uuid(params, "workspace_id")
        if params["workspace_id"] != nil && workspaceFilter == nil {
            return .finished(.err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil))
        }
        switch systemWindowRouting(params) {
        case .invalid(let error):
            return .finished(error)
        case .routed(let routing):
            let resolution = seam?.controlSystemTreeWindows(
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
                return .finished(systemWindowNotFound(params, windowID: requestedWindowID))
            }
            if let workspaceFilter, !resolution.workspaceFound {
                return .finished(.err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: .object([
                        "workspace_id": .string(workspaceFilter.uuidString),
                        "workspace_ref": ref(.workspace, workspaceFilter),
                    ])
                ))
            }

            return .resolved(
                focused: routing.focused,
                caller: routing.caller,
                windows: resolution.windows,
                refs: resolution.windows.map { systemTreeWindowRefs($0) }
            )
        }
    }

    // MARK: - Tree ref mint pass (inside the hop)

    /// The pre-minted refs of one `system.tree` window node, parallel to the
    /// node tree. Each level mints in its payload's literal order (window,
    /// selected workspace, then the nested workspaces / panes / surfaces), so
    /// a ref first minted during payload build keeps the identical ordinal.
    private struct SystemTreeWindowRefs: Sendable {
        let windowRef: JSONValue
        let selectedWorkspaceRef: JSONValue
        let workspaces: [SystemTreeWorkspaceRefs]
    }

    private struct SystemTreeWorkspaceRefs: Sendable {
        let workspaceRef: JSONValue
        let panes: [SystemTreePaneRefs]
    }

    private struct SystemTreePaneRefs: Sendable {
        let paneRef: JSONValue
        let surfaceRefs: [JSONValue]
        let selectedSurfaceRef: JSONValue
        let surfaces: [SystemTreeSurfaceRefs]
    }

    private struct SystemTreeSurfaceRefs: Sendable {
        let surfaceRef: JSONValue
        let paneRef: JSONValue
    }

    private func systemTreeWindowRefs(_ node: ControlSystemTreeWindowNode) -> SystemTreeWindowRefs {
        SystemTreeWindowRefs(
            windowRef: ref(.window, node.summary.windowID),
            selectedWorkspaceRef: ref(.workspace, node.summary.selectedWorkspaceID),
            workspaces: node.workspaces.map { systemTreeWorkspaceRefs($0) }
        )
    }

    private func systemTreeWorkspaceRefs(_ node: ControlSystemTreeWorkspaceNode) -> SystemTreeWorkspaceRefs {
        SystemTreeWorkspaceRefs(
            workspaceRef: ref(.workspace, node.workspaceID),
            panes: node.panes.map { systemTreePaneRefs($0) }
        )
    }

    private func systemTreePaneRefs(_ node: ControlSystemTreePaneNode) -> SystemTreePaneRefs {
        SystemTreePaneRefs(
            paneRef: ref(.pane, node.paneID),
            surfaceRefs: node.surfaceIDs.map { ref(.surface, $0) },
            selectedSurfaceRef: ref(.surface, node.selectedSurfaceID),
            surfaces: node.surfaces.map { systemTreeSurfaceRefs($0) }
        )
    }

    private func systemTreeSurfaceRefs(_ node: ControlSystemTreeSurfaceNode) -> SystemTreeSurfaceRefs {
        SystemTreeSurfaceRefs(
            surfaceRef: ref(.surface, node.surfaceID),
            paneRef: ref(.pane, node.paneID)
        )
    }

    // MARK: - Tree payload shaping (off-main, over pre-minted refs)

    /// The `system.tree` window node payload (the legacy `v2TreeWindowNode`).
    private nonisolated func systemTreeWindowPayload(
        _ node: ControlSystemTreeWindowNode,
        refs: SystemTreeWindowRefs
    ) -> JSONValue {
        .object([
            "id": .string(node.summary.windowID.uuidString),
            "ref": refs.windowRef,
            "index": .int(Int64(node.index)),
            "key": .bool(node.summary.isKeyWindow),
            "visible": .bool(node.summary.isVisible),
            "workspace_count": .int(Int64(node.workspaces.count)),
            "selected_workspace_id": orNull(node.summary.selectedWorkspaceID?.uuidString),
            "selected_workspace_ref": refs.selectedWorkspaceRef,
            "workspaces": .array(zip(node.workspaces, refs.workspaces).map { pair in systemTreeWorkspacePayload(pair.0, refs: pair.1) }),
        ])
    }

    /// The `system.tree` workspace node payload (the legacy
    /// `v2TreeWorkspaceNode`).
    private nonisolated func systemTreeWorkspacePayload(
        _ node: ControlSystemTreeWorkspaceNode,
        refs: SystemTreeWorkspaceRefs
    ) -> JSONValue {
        .object([
            "id": .string(node.workspaceID.uuidString),
            "ref": refs.workspaceRef,
            "index": .int(Int64(node.index)),
            "title": .string(node.title),
            "description": orNull(node.description),
            "selected": .bool(node.isSelected),
            "pinned": .bool(node.isPinned),
            "panes": .array(zip(node.panes, refs.panes).map { pair in systemTreePanePayload(pair.0, refs: pair.1) }),
        ])
    }

    /// The `system.tree` pane node payload.
    private nonisolated func systemTreePanePayload(
        _ node: ControlSystemTreePaneNode,
        refs: SystemTreePaneRefs
    ) -> JSONValue {
        .object([
            "id": .string(node.paneID.uuidString),
            "ref": refs.paneRef,
            "index": .int(Int64(node.index)),
            "focused": .bool(node.isFocused),
            "surface_ids": .array(node.surfaceIDs.map { .string($0.uuidString) }),
            "surface_refs": .array(refs.surfaceRefs),
            "selected_surface_id": orNull(node.selectedSurfaceID?.uuidString),
            "selected_surface_ref": refs.selectedSurfaceRef,
            "surface_count": .int(Int64(node.surfaceIDs.count)),
            "surfaces": .array(zip(node.surfaces, refs.surfaces).map { pair in systemTreeSurfacePayload(pair.0, refs: pair.1) }),
        ])
    }

    /// The `system.tree` surface node payload (browser surfaces emit their URL
    /// string — empty when absent — and non-browsers emit JSON `null`).
    private nonisolated func systemTreeSurfacePayload(
        _ node: ControlSystemTreeSurfaceNode,
        refs: SystemTreeSurfaceRefs
    ) -> JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(node.surfaceID.uuidString),
            "ref": refs.surfaceRef,
            "index": .int(Int64(node.index)),
            "type": .string(node.typeRawValue),
            "title": .string(node.title),
            "focused": .bool(node.isFocused),
            "selected": .bool(node.isSelected),
            "selected_in_pane": node.selectedInPane.map { JSONValue.bool($0) } ?? .null,
            "pane_id": orNull(node.paneID?.uuidString),
            "pane_ref": refs.paneRef,
            "index_in_pane": node.indexInPane.map { JSONValue.int(Int64($0)) } ?? .null,
            "tty": orNull(node.tty),
        ]
        item["url"] = node.isBrowser ? .string(node.url ?? "") : .null
        return .object(item)
    }
}
