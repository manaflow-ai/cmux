import AppKit
import Bonsplit
import CmuxControlSocket
import CmuxFoundation
import CmuxTerminal
import Foundation
import GhosttyKit

/// Builds the `debug.terminals` global terminal-surface debug table payload.
///
/// This body is irreducibly app-coupled: it walks live `NSWindow`, `NSView`,
/// and `ghostty_surface_t` internals (raw object/surface pointers, superview
/// class chains, portal-binding/host-lease state, occlusion, key state) to
/// build a dozens-of-fields-per-terminal `[String: Any]` payload. Per the
/// refactor LEARNINGS such a body stays in the executable app target rather than
/// moving into the control-plane package; this builder relocates the table-construction
/// logic out of `TerminalController`'s `debug.terminals` conformance witness so
/// the god file shrinks while the body stays exactly where its live state lives.
///
/// The two controller seams it still needs are injected: `orderedPanels`
/// reproduces `TerminalController.orderedPanels(in:)` (spatial panel order), and
/// `makeRef` reproduces `TerminalController.v2Ref(kind:uuid:)` (the handle-ref
/// registry). The trivial `v2OrNull` (`value ?? NSNull()`) is reproduced inline.
@MainActor
struct TerminalDebugTableBuilder {
    /// Live scriptable main-window states, in `AppDelegate.scriptableMainWindows()` order.
    let windows: [AppDelegate.ScriptableMainWindowState]
    /// Every live terminal surface from `GhosttyApp.terminalSurfaceRegistry`.
    let surfaces: [TerminalSurface]
    /// Seam reproducing `TerminalController.orderedPanels(in:)`.
    let orderedPanels: (Workspace) -> [any Panel]
    /// Seam reproducing `TerminalController.v2Ref(kind:uuid:)` (handle-ref registry).
    let makeRef: (ControlHandleKind, UUID?) -> Any

    /// Constructs the `{ "count": …, "terminals": [ … ] }` debug payload.
    func build() -> [String: Any] {
        func v2OrNull(_ value: Any?) -> Any {
            // Avoid relying on `?? NSNull()` inference (Swift toolchains can disagree).
            if let value { return value }
            return NSNull()
        }

        func v2Ref(kind: ControlHandleKind, uuid: UUID?) -> Any {
            makeRef(kind, uuid)
        }

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

                for (surfaceIndex, panel) in self.orderedPanels(workspace).enumerated() {
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
            let currentDirectory = (workspace?.panelDirectories[panelId] ?? mapped?.terminalPanel.directory)?.whitespaceTrimmedNilIfEmpty
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
                "window_title": v2OrNull(hostedWindow?.title?.whitespaceTrimmedNilIfEmpty),
                "window_class": v2OrNull(className(hostedWindow)),
                "window_delegate_class": v2OrNull(className(hostedWindow?.delegate as AnyObject?)),
                "window_controller_class": v2OrNull(className(hostedWindow?.windowController)),
                "window_level": v2OrNull(hostedWindow?.level.rawValue),
                "window_frame": hostedWindow.map { $0.frame.controlDebugRectPayload } ?? NSNull(),
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
                "hosted_view_frame": hostedView.frame.controlDebugRectPayload,
                "hosted_view_bounds": hostedView.bounds.controlDebugRectPayload,
                "hosted_view_frame_in_window": hostedView.debugPortalFrameInWindow.controlDebugRectPayload,
                "portal_binding_state": portalState.state,
                "portal_binding_generation": v2OrNull(portalState.generation),
                "portal_host_id": v2OrNull(portalHostLease.hostId),
                "portal_host_in_window": v2OrNull(portalHostLease.inWindow),
                "portal_host_area": v2OrNull(portalHostLease.area.map(Double.init)),
                "tty": v2OrNull(ttyName),
                "current_directory": v2OrNull(currentDirectory),
                "requested_working_directory": v2OrNull(terminalSurface.requestedWorkingDirectory?.whitespaceTrimmedNilIfEmpty),
                "initial_command": v2OrNull(terminalSurface.debugInitialCommand()?.whitespaceTrimmedNilIfEmpty),
                "tmux_start_command": v2OrNull(terminalSurface.debugTmuxStartCommand()?.whitespaceTrimmedNilIfEmpty),
                "git_branch": v2OrNull(gitBranchState?.branch.whitespaceTrimmedNilIfEmpty),
                "git_dirty": v2OrNull(gitBranchState?.isDirty),
                "listening_ports": listeningPorts,
                "key_state_indicator": v2OrNull(terminalSurface.currentKeyStateIndicatorText?.whitespaceTrimmedNilIfEmpty),
                "last_known_workspace_id": lastKnownWorkspaceId.uuidString,
                "last_known_workspace_ref": v2Ref(kind: .workspace, uuid: lastKnownWorkspaceId),
                "teardown_requested": teardownRequest.requestedAt != nil,
                "teardown_requested_at": v2OrNull(iso8601String(teardownRequest.requestedAt)),
                "teardown_requested_age_seconds": v2OrNull(ageSeconds(since: teardownRequest.requestedAt)),
                "teardown_requested_reason": v2OrNull(teardownRequest.reason?.whitespaceTrimmedNilIfEmpty)
            ]

            if title == nil, let fallbackTitle = mapped?.terminalPanel.displayTitle, !fallbackTitle.isEmpty {
                item["surface_title"] = fallbackTitle
            }
            return item
        }

        return [
            "count": terminals.count,
            "terminals": terminals
        ]
    }
}
