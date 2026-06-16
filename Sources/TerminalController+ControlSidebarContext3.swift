import AppKit
import Bonsplit
import CmuxControlSocket
import CmuxTerminal

/// The live-app half of the v1 bonsplit pane commands (`list_panes` /
/// `list_pane_surfaces` / `focus_pane` / `focus_surface_by_panel` /
/// `drag_surface_to_split` / `new_pane`) and the misc v1 surface ops
/// (`new_surface` / `close_surface` / `reload_config` / `refresh_surfaces` /
/// `surface_health`): the exact bodies the former `TerminalController` v1
/// handlers ran.
extension TerminalController {
    // MARK: - Pane listings / focus

    func controlSidebarPaneList() -> ControlSidebarPaneListSnapshot? {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        let paneIds = tab.bonsplitController.allPaneIds
        let focusedPaneId = tab.bonsplitController.focusedPaneId
        return ControlSidebarPaneListSnapshot(
            paneIDs: paneIds.map(\.id),
            focusedPaneID: focusedPaneId?.id,
            tabCounts: paneIds.map { tab.bonsplitController.tabs(inPane: $0).count }
        )
    }

    func controlSidebarPaneSurfaces(paneArg: String?) -> ControlSidebarPaneSurfacesResolution {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return .noTabSelected
        }

        let paneIds = tab.bonsplitController.allPaneIds
        var targetPaneId: PaneID? = tab.bonsplitController.focusedPaneId
        if let paneArg {
            if let uuid = UUID(uuidString: paneArg),
               let paneId = paneIds.first(where: { $0.id == uuid }) {
                targetPaneId = paneId
            } else if let index = Int(paneArg), index >= 0, index < paneIds.count {
                targetPaneId = paneIds[index]
            } else {
                return .paneNotFound
            }
        }

        guard let paneId = targetPaneId else {
            return .noPaneTarget
        }

        let tabs = tab.bonsplitController.tabs(inPane: paneId)
        let selectedTab = tab.bonsplitController.selectedTab(inPane: paneId)

        return .rows(tabs.map { bonsplitTab in
            ControlSidebarPaneSurfacesResolution.Row(
                isSelected: bonsplitTab.id == selectedTab?.id,
                title: bonsplitTab.title,
                panelIDString: tab.panelIdFromSurfaceId(bonsplitTab.id)?.uuidString
            )
        })
    }

    func controlSidebarFocusPane(paneArg: String) -> Bool {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return false
        }

        let paneIds = tab.bonsplitController.allPaneIds

        // Try UUID first, then fall back to index
        if let uuid = UUID(uuidString: paneArg),
           let paneId = paneIds.first(where: { $0.id == uuid }) {
            tab.bonsplitController.focusPane(paneId)
            return true
        } else if let index = Int(paneArg), index >= 0, index < paneIds.count {
            tab.bonsplitController.focusPane(paneIds[index])
            return true
        }
        return false
    }

    func controlSidebarFocusSurfaceByPanel(panelID: UUID) -> Bool {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return false
        }

        // Focus by panel UUID (our stable surface handle). This must also move AppKit
        // first responder into the terminal view to ensure typing routes correctly.
        guard tab.panels[panelID] != nil,
              tab.surfaceIdFromPanelId(panelID) != nil else {
            return false
        }
        tabManager.focusSurface(tabId: tab.id, surfaceId: panelID)
        return true
    }

    // MARK: - Drag to split / new pane

    func controlSidebarRefreshKnownRefs() {
        // The byte-faithful twin of the file-private `v2RefreshKnownRefs()`
        // (which stays in `TerminalController.swift` for the v2 dispatch
        // pre-pass), minting into the same coordinator-owned registry.
        guard let app = AppDelegate.shared else { return }

        let windows = app.listMainWindowSummaries()
        for item in windows {
            _ = controlCommandCoordinator.ensureRef(kind: .window, uuid: item.windowId)
            if let tm = app.tabManagerFor(windowId: item.windowId) {
                for ws in tm.tabs {
                    _ = controlCommandCoordinator.ensureRef(kind: .workspace, uuid: ws.id)
                    for paneId in ws.bonsplitController.allPaneIds {
                        _ = controlCommandCoordinator.ensureRef(kind: .pane, uuid: paneId.id)
                    }
                    for panelId in ws.panels.keys {
                        _ = controlCommandCoordinator.ensureRef(kind: .surface, uuid: panelId)
                    }
                }
                for group in tm.workspaceGroups {
                    _ = controlCommandCoordinator.ensureRef(kind: .workspaceGroup, uuid: group.id)
                }
            }
        }
    }

    func controlSidebarSplitOffSurface(surfaceID: UUID, directionRawValue: String) -> ControlSidebarSplitOffOutcome {
        switch v2SurfaceSplitOff(params: [
            "surface_id": surfaceID.uuidString,
            "direction": directionRawValue,
            "focus": false
        ]) {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            return .ok(paneID: (dict?["pane_id"] as? String) ?? "")
        case .err(_, let message, _):
            return .error(message: message)
        }
    }

    func controlSidebarDragSurfaceToSplit(
        surfaceArg: String,
        orientationIsHorizontal: Bool,
        insertFirst: Bool
    ) -> ControlSidebarDragToSplitResolution {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return .noTabSelected
        }

        guard let panelId = controlSidebarResolveSurfaceId(from: surfaceArg, tab: tab),
              let bonsplitTabId = tab.surfaceIdFromPanelId(panelId) else {
            return .surfaceNotFound
        }

        let orientation: SplitOrientation = orientationIsHorizontal ? .horizontal : .vertical
        guard let newPaneId = tab.bonsplitController.splitPane(
            orientation: orientation,
            movingTab: bonsplitTabId,
            insertFirst: insertFirst
        ) else {
            return .splitFailed
        }

        return .moved(newPaneID: newPaneId.id)
    }

    func controlSidebarCreatePaneSplit(
        isBrowser: Bool,
        orientationIsHorizontal: Bool,
        insertFirst: Bool,
        url: URL?
    ) -> ControlSidebarPaneSplitResolution {
        let focus = Self.socketCommandAllowsInAppFocusMutations()
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let focusedPanelId = tab.focusedPanelId else {
            return .failed
        }

        let orientation: SplitOrientation = orientationIsHorizontal ? .horizontal : .vertical
        if isBrowser {
            guard let id = tab.newBrowserSplit(
                from: focusedPanelId,
                orientation: orientation,
                insertFirst: insertFirst,
                url: url,
                focus: focus,
                creationPolicy: .automationPreload
            )?.id else {
                return .failed
            }
            return .created(id)
        }
        if tab.isRemoteTmuxMirror, insertFirst {
            // Routed tmux `split-window` cannot insert before the target
            // pane; reject before mutating the remote session.
            return .mirrorInsertFirstRejected
        }
        switch tab.newTerminalSplitOutcome(
            from: focusedPanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: focus
        ) {
        case .created(let panel):
            return .created(panel.id)
        case .routedToRemote:
            return .routedToRemote
        case .failed:
            return .failed
        }
    }

    // MARK: - New / close surface

    func controlSidebarNewSurface(isBrowser: Bool, paneArg: String?, url: URL?) -> ControlSidebarNewSurfaceResolution {
        let focus = Self.socketCommandAllowsInAppFocusMutations()
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return .noTabSelected
        }

        // Get target pane
        let paneId: PaneID?
        let paneIds = tab.bonsplitController.allPaneIds
        if let paneArg {
            if let uuid = UUID(uuidString: paneArg) {
                paneId = paneIds.first(where: { $0.id == uuid })
            } else if let idx = Int(paneArg), idx >= 0, idx < paneIds.count {
                paneId = paneIds[idx]
            } else {
                paneId = nil
            }
        } else {
            paneId = tab.bonsplitController.focusedPaneId
        }

        guard let targetPaneId = paneId else {
            return .paneNotFound
        }

        if isBrowser {
            guard let id = tab.newBrowserSurface(
                inPane: targetPaneId,
                url: url,
                focus: focus,
                creationPolicy: .automationPreload
            )?.id else {
                return .failed
            }
            return .created(id)
        }
        switch tab.newTerminalSurfaceOutcome(
            inPane: targetPaneId,
            focus: focus,
            inheritWorkingDirectoryFallback: true
        ) {
        case .created(let panel):
            return .created(panel.id)
        case .routedToRemote:
            return .routedToRemote
        case .failed:
            return .failed
        }
    }

    func controlSidebarCloseSurface(surfaceArg: String?) -> ControlSidebarCloseSurfaceResolution {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return .noTabSelected
        }

        // Resolve surface ID from argument or use focused
        let surfaceId: UUID?
        if let surfaceArg {
            surfaceId = controlSidebarResolveSurfaceId(from: surfaceArg, tab: tab)
        } else {
            surfaceId = tab.focusedPanelId
        }

        guard let targetSurfaceId = surfaceId else {
            return .surfaceNotFound
        }

        // Don't close if it's the only surface
        if tab.panels.count <= 1 {
            return .lastSurface
        }

        // Socket commands must be non-interactive: bypass close-confirmation gating.
        guard controlSidebarCloseSurfaceRecordingHistory(in: tab, surfaceId: targetSurfaceId, force: true) else {
            return .closeFailed
        }
        return .closed
    }

    /// The byte-faithful twin of the file-private `resolveSurfaceId(from:tab:)`
    /// (which stays in `TerminalController.swift` for `focus_surface`).
    private func controlSidebarResolveSurfaceId(from arg: String, tab: Workspace) -> UUID? {
        if let uuid = UUID(uuidString: arg), tab.panels[uuid] != nil {
            return uuid
        }

        if let index = Int(arg), index >= 0 {
            let panels = orderedPanels(in: tab)
            guard index < panels.count else { return nil }
            return panels[index].id
        }

        return nil
    }

    /// The byte-faithful twin of the file-private `closeSurfaceRecordingHistory`
    /// (which stays in `TerminalController.swift` for the v2 surface paths).
    private func controlSidebarCloseSurfaceRecordingHistory(
        in workspace: Workspace,
        surfaceId: UUID,
        force: Bool
    ) -> Bool {
        if let tabId = workspace.surfaceIdFromPanelId(surfaceId) {
            if force {
                return workspace.requestNonInteractiveCloseTabRecordingHistory(tabId)
            }
            return workspace.requestCloseTabRecordingHistory(tabId, force: force)
        }

        workspace.markCloseHistoryEligible(panelId: surfaceId)
        return workspace.closePanel(surfaceId, force: force)
    }

    // MARK: - Misc ops

    func controlSidebarReloadConfig() {
        if let appDelegate = AppDelegate.shared {
            appDelegate.reloadConfiguration(source: "socket.reload_config")
        } else {
            GhosttyApp.shared.reloadConfiguration(source: "socket.reload_config")
        }
    }

    func controlSidebarRefreshSurfaces() -> Int {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return 0
        }

        // Force-refresh all terminal panels in current tab
        // (resets cached metrics so the Metal layer drawable resizes correctly)
        var refreshedCount = 0
        for panel in tab.panels.values {
            if let terminalPanel = panel as? TerminalPanel {
                terminalPanel.surface.forceRefresh(reason: "terminalController.refreshAllTerminalPanels")
                refreshedCount += 1
            }
        }
        return refreshedCount
    }

    func controlSidebarSurfaceHealth(tabArg: String) -> [ControlSidebarSurfaceHealthRow]? {
        guard let tabManager,
              let tab = controlSidebarResolveTab(from: tabArg, tabManager: tabManager) else {
            return nil
        }
        let panels = orderedPanels(in: tab)
        return panels.map { panel in
            let kind: ControlSidebarSurfaceHealthRow.Kind
            if let tp = panel as? TerminalPanel {
                kind = .terminal(
                    inWindow: tp.surface.isViewInWindow,
                    portalHosted: controlSidebarIsPortalHosted(tp.hostedView),
                    viewDepth: controlSidebarViewDepth(of: tp.hostedView)
                )
            } else if let bp = panel as? BrowserPanel {
                kind = .browser(inWindow: bp.webView.window != nil)
            } else {
                kind = .other
            }
            return ControlSidebarSurfaceHealthRow(
                panelID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                kind: kind
            )
        }
    }

    /// The byte-faithful twin of the deleted file-private `viewDepth(of:maxDepth:)`.
    private func controlSidebarViewDepth(of view: NSView, maxDepth: Int = 128) -> Int {
        var depth = 0
        var current: NSView? = view
        while let v = current, depth < maxDepth {
            current = v.superview
            depth += 1
        }
        return depth
    }

    /// The byte-faithful twin of the deleted file-private `isPortalHosted(_:)`.
    private func controlSidebarIsPortalHosted(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is WindowTerminalHostView { return true }
            current = v.superview
        }
        return false
    }
}
