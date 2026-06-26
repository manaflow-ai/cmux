import AppKit
import Bonsplit
import CmuxControlSocket
import CmuxTerminal
import Foundation
import GhosttyKit

/// The surface-domain input / read / resume / reporting witnesses, plus the
/// `surface.move` bridge and `debug.terminals` passthrough. Split out of
/// `TerminalController+ControlSurfaceContext` to keep the conformance readable; see
/// that file's doc comment for the overview.
extension TerminalController {

    // MARK: - move (bridge to still-app-side v2SurfaceMove)

    func controlSurfaceMove(params: [String: JSONValue]) -> ControlCallResult {
        // `v2SurfaceMove` walks windows/workspaces/panes and mutates Bonsplit; it
        // stays in TerminalController.swift (shared with pane.join). We forward the
        // raw params and bridge its Foundation result, exactly as pane.join does.
        let foundationParams = params.mapValues(\.foundationObject)
        switch v2SurfaceMove(params: foundationParams) {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) })
        }
    }

    // MARK: - reorder

    func controlSurfaceReorder(
        surfaceID: UUID,
        inputs: ControlSurfaceReorderInputs,
        requestedFocus: Bool
    ) -> ControlSurfaceReorderResolution {
        let focus = v2FocusAllowed(requested: requestedFocus)
        guard let app = AppDelegate.shared,
              let located = app.locateSurface(surfaceId: surfaceID),
              let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              let sourcePane = ws.paneId(forPanelId: surfaceID) else {
            return .surfaceNotFound(surfaceID)
        }

        let targetIndex: Int
        if let index = inputs.index {
            targetIndex = index
        } else if let beforeSurfaceID = inputs.beforeSurfaceID {
            guard let anchorPane = ws.paneId(forPanelId: beforeSurfaceID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: beforeSurfaceID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex
        } else if let afterSurfaceID = inputs.afterSurfaceID {
            guard let anchorPane = ws.paneId(forPanelId: afterSurfaceID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: afterSurfaceID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex + 1
        } else {
            // Unreachable: the coordinator enforces exactly-one-target.
            return .reorderFailed
        }

        guard ws.reorderSurface(panelId: surfaceID, toIndex: targetIndex, focus: focus) else {
            return .reorderFailed
        }
        return .reordered(
            windowID: located.windowId,
            workspaceID: ws.id,
            paneID: sourcePane.id,
            surfaceID: surfaceID
        )
    }

    // MARK: - refresh

    func controlSurfaceRefresh(routing: ControlRoutingSelectors) -> ControlSurfaceRefreshResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        var refreshedCount = 0
        for panel in ws.panels.values {
            if let terminalPanel = panel as? TerminalPanel {
                terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceRefresh")
                refreshedCount += 1
            }
        }
        return .refreshed(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            refreshedCount: refreshedCount
        )
    }

    // MARK: - clear_history

    func controlSurfaceClearHistory(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool
    ) -> ControlSurfaceClearHistoryResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        // Legacy: a present-but-unparseable surface_id errors; it must never fall
        // back to clearing the focused surface (wrong-target side effect).
        if hasSurfaceIDParam, surfaceID == nil {
            return .surfaceNotFoundForID
        }
        guard let surfaceId = surfaceID ?? ws.focusedPanelId else {
            return .noFocusedSurface
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }
        guard terminalPanel.performBindingAction("clear_screen") else {
            return .bindingActionUnavailable
        }
        terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceClearHistory")
        return .cleared(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId
        )
    }

    // MARK: - trigger_flash

    func controlSurfaceTriggerFlash(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceTriggerFlashResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let surfaceId = surfaceID ?? ws.focusedPanelId else {
            return .noFocusedSurface
        }
        guard ws.panels[surfaceId] != nil else {
            return .surfaceNotFound(surfaceId)
        }
        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)
        ws.triggerFocusFlash(panelId: surfaceId)
        return .flashed(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId
        )
    }

    // MARK: - send_text / send_key

    func controlSurfaceInputStrings() -> ControlSurfaceInputStrings {
        ControlSurfaceInputStrings(
            inputQueueFull: String(
                localized: "socket.terminal.inputQueueFull",
                defaultValue: "The terminal can't accept more input right now. Wait a moment and retry, or reopen the terminal if it stays unavailable."
            ),
            surfaceUnavailable: String(
                localized: "socket.terminal.surfaceUnavailable",
                defaultValue: "The terminal surface is no longer available; reopen it or create a new terminal session."
            ),
            processExited: String(
                localized: "socket.terminal.processExited",
                defaultValue: "The terminal session has ended; reopen it or create a new terminal session."
            )
        )
    }

    /// Resolves the send target surface, matching the legacy
    /// `params["surface_id"] != nil` branch (an explicit param that did not parse
    /// signals `surfaceNotFoundForID`; otherwise the focused surface).
    /// The send-target resolution outcome (a domain value, not an `Error`, so it
    /// is not a `Result.Failure`).
    private enum SendSurfaceTarget {
        case surface(UUID)
        case unresolved(ControlSurfaceSendResolution)
    }

    private func resolveSendSurface(
        in ws: Workspace,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool
    ) -> SendSurfaceTarget {
        if hasSurfaceIDParam {
            guard let surfaceId = surfaceID else {
                return .unresolved(.surfaceNotFoundForID)
            }
            return .surface(surfaceId)
        }
        guard let focused = ws.focusedPanelId else {
            return .unresolved(.noFocusedSurface)
        }
        return .surface(focused)
    }

    func controlSurfaceSendText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        text: String
    ) -> ControlSurfaceSendResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let surfaceId: UUID
        switch resolveSendSurface(in: ws, surfaceID: surfaceID, hasSurfaceIDParam: hasSurfaceIDParam) {
        case .unresolved(let resolution): return resolution
        case .surface(let id): surfaceId = id
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }
        let queued: Bool
        switch terminalPanel.sendInputResult(text) {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendText")
            queued = false
        case .queued:
            queued = true
        case .inputQueueFull:
            return .inputQueueFull(surfaceId)
        case .surfaceUnavailable:
            return .surfaceUnavailable(surfaceId)
        case .processExited:
            return .processExited(surfaceId)
        }
        return .sent(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId,
            queued: queued
        )
    }

    func controlSurfaceSendKey(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        key: String
    ) -> ControlSurfaceSendResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let surfaceId: UUID
        switch resolveSendSurface(in: ws, surfaceID: surfaceID, hasSurfaceIDParam: hasSurfaceIDParam) {
        case .unresolved(let resolution): return resolution
        case .surface(let id): surfaceId = id
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }
        let sendResult = terminalPanel.sendNamedKeyResult(key)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendKey")
        case .queued:
            break
        case .unknownKey:
            return .unknownKey
        case .inputQueueFull:
            return .inputQueueFull(surfaceId)
        case .surfaceUnavailable:
            return .surfaceUnavailable(surfaceId)
        case .processExited:
            return .processExited(surfaceId)
        }
        return .sent(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId,
            queued: sendResult == .queued
        )
    }

    // MARK: - read_text

    func controlSurfaceReadText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> ControlSurfaceReadTextResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let surfaceId: UUID
        if hasSurfaceIDParam {
            guard let id = surfaceID else { return .surfaceNotFoundForID }
            surfaceId = id
        } else {
            guard let focused = ws.focusedPanelId else { return .noFocusedSurface }
            surfaceId = focused
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }

        guard let rawSnapshot = readTerminalTextRawSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback
        ) else {
            return .internalError(message: "Failed to read terminal text")
        }
        switch TerminalTextPayload.make(
            from: rawSnapshot,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) {
        case .success(let payload):
            return .read(
                text: payload.text,
                base64: payload.base64,
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: ws.id,
                surfaceID: surfaceId
            )
        case .failure(let error):
            return .internalError(message: error.message)
        }
    }

    // MARK: - debug.terminals

    /// `debug.terminals` — the global terminal-surface debug table.
    ///
    /// This body is irreducibly app-coupled: it walks live `NSWindow`,
    /// `NSView`, and `ghostty_surface_t` internals (raw object/surface pointers,
    /// superview class chains, portal-binding/host-lease state, occlusion, key
    /// state) to build a dozens-of-fields-per-terminal `[String: Any]` payload.
    /// Per the refactor LEARNINGS, such a body stays in the executable app
    /// target as a documented passthrough rather than moving into the
    /// control-plane package. It was drained out of `TerminalController.swift`
    /// (the former `v2DebugTerminals(params:)`) into this conformance witness so
    /// the god file shrinks while the body stays exactly where its live state
    /// lives. The legacy method ignored its params, so the seam takes none; the
    /// Foundation dictionary bridges to `JSONValue` for the wire, and a `nil`
    /// payload (the legacy `unavailable` error when `AppDelegate` is gone) maps
    /// to `nil`, which the coordinator turns into the same `unavailable` error.
    func controlDebugTerminals() -> JSONValue? {
        var payload: [String: Any]?

        v2MainSync {
            guard let app = AppDelegate.shared else { return }

            struct MappedTerminalLocation {
                let windowIndex: Int
                let windowId: UUID
                let window: NSWindow?
                let workspaceIndex: Int
                let workspaceSelected: Bool
                let workspace: Workspace
                let terminalPanel: TerminalPanel
                let paneId: PaneID?
                let paneIndex: Int?
                let surfaceIndex: Int
                let selectedInPane: Bool?
                let bonsplitTabId: TabID?
            }

            func nonEmpty(_ raw: String?) -> String? {
                guard let raw else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            func rectPayload(_ rect: CGRect) -> [String: Double] {
                [
                    "x": Double(rect.origin.x),
                    "y": Double(rect.origin.y),
                    "width": Double(rect.size.width),
                    "height": Double(rect.size.height)
                ]
            }

            func objectPointerString(_ object: AnyObject?) -> String {
                guard let object else { return "nil" }
                return String(describing: Unmanaged.passUnretained(object).toOpaque())
            }

            func ghosttyPointerString(_ surface: ghostty_surface_t?) -> String {
                guard let surface else { return "nil" }
                return String(describing: surface)
            }

            func className(_ object: AnyObject?) -> String? {
                guard let object else { return nil }
                return String(describing: type(of: object))
            }

            let iso8601Formatter = ISO8601DateFormatter()
            let now = Date()

            func iso8601String(_ date: Date?) -> String? {
                guard let date else { return nil }
                return iso8601Formatter.string(from: date)
            }

            func ageSeconds(since date: Date?) -> Double? {
                guard let date else { return nil }
                return (now.timeIntervalSince(date) * 1000).rounded() / 1000
            }

            @MainActor
            func superviewClassChain(for view: NSView, limit: Int = 8) -> [String] {
                var chain: [String] = [String(describing: type(of: view))]
                var currentSuperview = view.superview
                while chain.count < limit, let nextSuperview = currentSuperview {
                    chain.append(String(describing: type(of: nextSuperview)))
                    currentSuperview = nextSuperview.superview
                }
                if currentSuperview != nil {
                    chain.append("...")
                }
                return chain
            }

            let windows = app.scriptableMainWindows()
            let windowIndexById = Dictionary(
                uniqueKeysWithValues: windows.enumerated().map { ($0.element.windowId, $0.offset) }
            )

            @MainActor
            func resolvedWindowMetadata(for window: NSWindow?) -> (windowId: UUID?, windowIndex: Int?) {
                guard let window else { return (nil, nil) }

                if let match = windows.enumerated().first(where: { _, state in
                    guard let stateWindow = state.window else { return false }
                    return stateWindow === window || stateWindow.windowNumber == window.windowNumber
                }) {
                    return (match.element.windowId, match.offset)
                }

                guard let raw = window.identifier?.rawValue else { return (nil, nil) }
                let prefix = "cmux.main."
                guard raw.hasPrefix(prefix),
                      let parsedWindowId = UUID(uuidString: String(raw.dropFirst(prefix.count))) else {
                    return (nil, nil)
                }
                return (parsedWindowId, windowIndexById[parsedWindowId])
            }

            var mappedLocations: [ObjectIdentifier: MappedTerminalLocation] = [:]
            for (windowIndex, state) in windows.enumerated() {
                let tabManager = state.tabManager
                for (workspaceIndex, workspace) in tabManager.tabs.enumerated() {
                    let paneIndexById = Dictionary(
                        uniqueKeysWithValues: workspace.bonsplitController.allPaneIds.enumerated().map {
                            ($0.element.id, $0.offset)
                        }
                    )
                    var selectedInPaneByPanelId: [UUID: Bool] = [:]
                    for paneId in workspace.bonsplitController.allPaneIds {
                        let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
                        for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                            selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
                        }
                    }

                    for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
                        guard let terminalPanel = panel as? TerminalPanel else { continue }
                        mappedLocations[ObjectIdentifier(terminalPanel.surface)] = MappedTerminalLocation(
                            windowIndex: windowIndex,
                            windowId: state.windowId,
                            window: state.window,
                            workspaceIndex: workspaceIndex,
                            workspaceSelected: workspace.id == tabManager.selectedTabId,
                            workspace: workspace,
                            terminalPanel: terminalPanel,
                            paneId: workspace.paneId(forPanelId: terminalPanel.id),
                            paneIndex: workspace.paneId(forPanelId: terminalPanel.id).flatMap { paneIndexById[$0.id] },
                            surfaceIndex: surfaceIndex,
                            selectedInPane: selectedInPaneByPanelId[terminalPanel.id],
                            bonsplitTabId: workspace.surfaceIdFromPanelId(terminalPanel.id)
                        )
                    }
                }
            }

            let surfaces = GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces()
            let terminals: [[String: Any]] = surfaces.enumerated().map { index, terminalSurface in
                let mapped = mappedLocations[ObjectIdentifier(terminalSurface)]
                let hostedView = terminalSurface.hostedView
                let hostedWindow = mapped?.window ?? terminalSurface.uiWindow
                let fallbackWindowMetadata = resolvedWindowMetadata(for: hostedWindow)
                let resolvedWindowId = mapped?.windowId ?? fallbackWindowMetadata.windowId
                let resolvedWindowIndex = mapped?.windowIndex ?? fallbackWindowMetadata.windowIndex
                let workspace = mapped?.workspace
                let panelId = mapped?.terminalPanel.id ?? terminalSurface.id
                let portalState = hostedView.portalBindingGuardState()
                let portalHostLease = terminalSurface.debugPortalHostLease()
                let gitBranchState = workspace?.panelGitBranches[panelId]
                let listeningPorts = (workspace?.surfaceListeningPorts[panelId] ?? []).sorted()
                let title = workspace?.panelTitle(panelId: panelId)
                let paneId = mapped?.paneId
                let treeVisible = mapped?.bonsplitTabId != nil && paneId != nil
                let ttyName = workspace?.surfaceTTYNames[panelId]
                let currentDirectory = nonEmpty(workspace?.panelDirectories[panelId] ?? mapped?.terminalPanel.directory)
                let teardownRequest = terminalSurface.debugTeardownRequest()
                let lastKnownWorkspaceId = terminalSurface.debugLastKnownWorkspaceId()

                var item: [String: Any] = [
                    "index": index,
                    "mapped": mapped != nil,
                    "tree_visible": treeVisible,
                    "window_index": v2OrNull(resolvedWindowIndex),
                    "window_id": v2OrNull(resolvedWindowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: resolvedWindowId),
                    "window_number": v2OrNull(hostedWindow?.windowNumber),
                    "window_key": hostedWindow?.isKeyWindow ?? false,
                    "window_main": hostedWindow?.isMainWindow ?? false,
                    "window_visible": hostedWindow?.isVisible ?? false,
                    "window_occluded": hostedWindow.map { !$0.occlusionState.contains(.visible) } ?? false,
                    "window_identifier": v2OrNull(hostedWindow?.identifier?.rawValue),
                    "window_title": v2OrNull(nonEmpty(hostedWindow?.title)),
                    "window_class": v2OrNull(className(hostedWindow)),
                    "window_delegate_class": v2OrNull(className(hostedWindow?.delegate as AnyObject?)),
                    "window_controller_class": v2OrNull(className(hostedWindow?.windowController)),
                    "window_level": v2OrNull(hostedWindow?.level.rawValue),
                    "window_frame": hostedWindow.map { rectPayload($0.frame) } ?? NSNull(),
                    "workspace_index": v2OrNull(mapped?.workspaceIndex),
                    "workspace_id": v2OrNull(workspace?.id.uuidString),
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace?.id),
                    "workspace_title": v2OrNull(workspace?.title),
                    "workspace_selected": v2OrNull(mapped?.workspaceSelected),
                    "pane_index": v2OrNull(mapped?.paneIndex),
                    "pane_id": v2OrNull(paneId?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneId?.id),
                    "surface_index": v2OrNull(mapped?.surfaceIndex),
                    "surface_index_in_pane": v2OrNull(workspace?.indexInPane(forPanelId: panelId)),
                    "surface_id": panelId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: panelId),
                    "surface_title": v2OrNull(title),
                    "surface_focused": v2OrNull(workspace.map { panelId == $0.focusedPanelId }),
                    "surface_selected_in_pane": v2OrNull(mapped?.selectedInPane),
                    "surface_pinned": v2OrNull(workspace.map { $0.isPanelPinned(panelId) }),
                    "surface_context": terminalSurface.debugSurfaceContextLabel(),
                    "surface_created_at": v2OrNull(iso8601String(terminalSurface.debugCreatedAt())),
                    "surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugCreatedAt())),
                    "runtime_surface_created_at": v2OrNull(iso8601String(terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "runtime_surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "bonsplit_tab_id": v2OrNull(mapped?.bonsplitTabId?.uuid.uuidString),
                    "terminal_object_ptr": objectPointerString(terminalSurface),
                    "ghostty_surface_ptr": ghosttyPointerString(terminalSurface.surface),
                    "runtime_surface_ready": terminalSurface.surface != nil,
                    "hosted_view_ptr": objectPointerString(hostedView),
                    "hosted_view_class": className(hostedView) ?? "nil",
                    "hosted_view_in_window": terminalSurface.isViewInWindow,
                    "hosted_view_in_headless_bootstrap_window": terminalSurface.isHeadlessStartupWindow(hostedView.window),
                    "hosted_view_has_superview": hostedView.superview != nil,
                    "hosted_view_hidden": hostedView.isHidden,
                    "hosted_view_hidden_or_ancestor_hidden": hostedView.isHiddenOrHasHiddenAncestor,
                    "hosted_view_alpha": hostedView.alphaValue,
                    "hosted_view_visible_in_ui": hostedView.debugPortalVisibleInUI,
                    "hosted_view_superview_chain": superviewClassChain(for: hostedView),
                    "surface_view_first_responder": hostedView.isSurfaceViewFirstResponder(),
                    "hosted_view_frame": rectPayload(hostedView.frame),
                    "hosted_view_bounds": rectPayload(hostedView.bounds),
                    "hosted_view_frame_in_window": rectPayload(hostedView.debugPortalFrameInWindow),
                    "portal_binding_state": portalState.state,
                    "portal_binding_generation": v2OrNull(portalState.generation),
                    "portal_host_id": v2OrNull(portalHostLease.hostId),
                    "portal_host_in_window": v2OrNull(portalHostLease.inWindow),
                    "portal_host_area": v2OrNull(portalHostLease.area.map(Double.init)),
                    "tty": v2OrNull(ttyName),
                    "current_directory": v2OrNull(currentDirectory),
                    "requested_working_directory": v2OrNull(nonEmpty(terminalSurface.requestedWorkingDirectory)),
                    "initial_command": v2OrNull(nonEmpty(terminalSurface.debugInitialCommand())),
                    "tmux_start_command": v2OrNull(nonEmpty(terminalSurface.debugTmuxStartCommand())),
                    "git_branch": v2OrNull(nonEmpty(gitBranchState?.branch)),
                    "git_dirty": v2OrNull(gitBranchState?.isDirty),
                    "listening_ports": listeningPorts,
                    "key_state_indicator": v2OrNull(nonEmpty(terminalSurface.currentKeyStateIndicatorText)),
                    "last_known_workspace_id": lastKnownWorkspaceId.uuidString,
                    "last_known_workspace_ref": v2Ref(kind: .workspace, uuid: lastKnownWorkspaceId),
                    "teardown_requested": teardownRequest.requestedAt != nil,
                    "teardown_requested_at": v2OrNull(iso8601String(teardownRequest.requestedAt)),
                    "teardown_requested_age_seconds": v2OrNull(ageSeconds(since: teardownRequest.requestedAt)),
                    "teardown_requested_reason": v2OrNull(nonEmpty(teardownRequest.reason))
                ]

                if title == nil, let fallbackTitle = mapped?.terminalPanel.displayTitle, !fallbackTitle.isEmpty {
                    item["surface_title"] = fallbackTitle
                }
                return item
            }

            payload = [
                "count": terminals.count,
                "terminals": terminals
            ]
        }

        guard let payload else { return nil }
        return JSONValue(foundationObject: payload)
    }
}
