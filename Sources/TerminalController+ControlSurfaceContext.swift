import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import GhosttyKit

extension TerminalController {
    /// Socket error text extracted because `TerminalController.swift` sits at
    /// its file-length budget.
    nonisolated static var terminalSurfaceUnavailableSocketError: String {
        "ERROR: \(terminalSurfaceUnavailableMessage)"
    }
}

/// The surface-domain witnesses are the byte-faithful bodies of the former
/// `v2Surface*` / `v2DebugTerminals` dispatchers, minus the per-read `v2MainSync`
/// hop: the coordinator already runs on the main actor inside the socket-command
/// policy scope, so each hop would re-apply the identical thread-local
/// focus-allowance stack — a no-op.
///
/// App-coupled resolution (`resolveTabManager(routing:)`, `v2ResolveWindowId`, the
/// Bonsplit layout, surface creation/move, the Ghostty reads, the resume approval
/// flow, the `debug.terminals` table) stays here; the seam exposes only Sendable
/// snapshots, resolution enums, and one bridged ``JSONValue`` (`debug.terminals`).
/// Every blocking `NSAlert` and `String(localized:)` resolves here, in the app
/// bundle, so translations survive.
extension TerminalController: ControlSurfaceContext {
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    /// The routing twin of the legacy `v2ResolveWorkspace(params:tabManager:)`.
    /// `internal` (not `private`) so the surface witnesses in the sibling
    /// `+ControlSurfaceContext2`/`3` files share it.
    func resolveSurfaceWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let wsId = routing.workspaceID {
            guard !AppDelegate.isWindowDockRoutingId(wsId) else { return nil }
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            if let workspace = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil }) {
                return workspace
            }
            if let workspace = tabManager.tabs.first(where: {
                $0.remoteTmuxControlPane(surfaceID: surfaceId) != nil
            }) {
                return workspace
            }
            guard windowDockContainingPanel(surfaceId) == nil else { return nil }
            return tabManager.tabs.first(where: { $0.containsDockPanel(surfaceId) })
        }
        if let paneId = routing.paneID {
            if let located = v2LocatePane(paneId) {
                guard located.tabManager === tabManager else { return nil }
                return located.workspace
            }
            if let workspace = tabManager.tabs.first(where: {
                $0.remoteTmuxControlPane(paneID: paneId) != nil
            }) {
                return workspace
            }
            guard windowDockContainingPane(paneId) == nil else { return nil }
            if let located = locateDockPane(paneId), located.tabManager === tabManager {
                return located.workspace
            }
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// Converts an app resume-binding snapshot (after `applyingStoredApproval`) into
    /// the seam value type, byte-faithful to `v2SurfaceResumeBindingPayload`.
    /// `internal` (not `private`) so the resume witnesses in the sibling
    /// `+ControlSurfaceContext3` file share it.
    func controlResumeBinding(
        from binding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceResumeBinding? {
        guard let binding else { return nil }
        let effective = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        return ControlSurfaceResumeBinding(
            name: effective.name,
            kind: effective.kind,
            command: effective.command,
            cwd: effective.cwd,
            checkpointID: effective.checkpointId,
            source: effective.source,
            environment: effective.environment,
            autoResume: effective.allowsAutomaticResume,
            approvalPolicyRawValue: effective.approvalPolicy?.rawValue,
            approvalRecordID: effective.approvalRecordId,
            updatedAt: effective.updatedAt
        )
    }

    // MARK: - list

    func controlSurfaceList(routing: ControlRoutingSelectors) -> ControlSurfaceListSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            return controlDockSurfaceList(dock: dock, tabManager: tabManager)
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }

        return ControlSurfaceListSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: controlSurfaceSummaries(workspace: ws)
        )
    }

    private func controlDockSurfaceList(
        dock: DockSplitStore,
        tabManager: TabManager
    ) -> ControlSurfaceListSnapshot {
        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]
        for paneId in dock.bonsplitController.allPaneIds {
            let tabs = dock.bonsplitController.tabs(inPane: paneId)
            let selected = dock.bonsplitController.selectedTab(inPane: paneId)
            for (idx, tab) in tabs.enumerated() {
                guard let panel = dock.panel(for: tab.id) else { continue }
                paneByPanelId[panel.id] = paneId.id
                indexInPaneByPanelId[panel.id] = idx
                selectedInPaneByPanelId[panel.id] = (tab.id == selected?.id)
            }
        }

        let focusedSurfaceId = dock.focusedPanelId
        let surfaces: [ControlSurfaceSummary] = orderedPanels(in: dock).map { panel in
            let terminalPanel = panel as? TerminalPanel
            return ControlSurfaceSummary(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                title: dockPanelTitle(panel, in: dock),
                isFocused: panel.id == focusedSurfaceId,
                paneID: paneByPanelId[panel.id],
                indexInPane: indexInPaneByPanelId[panel.id],
                selectedInPane: selectedInPaneByPanelId[panel.id],
                developerToolsVisible: (panel as? BrowserPanel)?.isDeveloperToolsVisible(),
                requestedWorkingDirectory: terminalPanel.flatMap {
                    v2NonEmptyString($0.requestedWorkingDirectory)
                },
                initialCommand: terminalPanel.flatMap {
                    v2NonEmptyString($0.surface.debugInitialCommand())
                },
                tmuxStartCommand: terminalPanel.flatMap {
                    v2NonEmptyString($0.surface.debugTmuxStartCommand())
                },
                isTerminal: terminalPanel != nil,
                resumeBinding: nil
            )
        }

        return ControlSurfaceListSnapshot(
            workspaceID: dock.workspaceId,
            windowID: dockResultWindowId(for: dock, tabManager: tabManager),
            surfaces: surfaces
        )
    }

    // MARK: - current

    func controlSurfaceCurrent(routing: ControlRoutingSelectors) -> ControlSurfaceCurrentSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let surfaceId = dock.focusedPanelId ?? orderedPanels(in: dock).first?.id
            let paneId = surfaceId.flatMap { dock.paneId(forPanelId: $0)?.id }
            return ControlSurfaceCurrentSnapshot(
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                workspaceID: dock.workspaceId,
                paneID: paneId,
                surfaceID: surfaceId,
                surfaceTypeRawValue: surfaceId.flatMap { dock.panels[$0]?.panelType.rawValue }
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let containerPanelID = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
        let projection = containerPanelID.flatMap {
            ws.controlSurfaceProjection(forContainerPanelID: $0)
        }
        return ControlSurfaceCurrentSnapshot(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: projection?.paneID,
            surfaceID: projection?.surfaceID,
            surfaceTypeRawValue: projection?.panel.panelType.rawValue
        )
    }

    // MARK: - health

    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let items: [ControlSurfaceHealthEntry] = orderedPanels(in: dock).map { panel in
                var inWindow: Bool?
                if let tp = panel as? TerminalPanel {
                    inWindow = tp.surface.isViewInWindow
                } else if let bp = panel as? BrowserPanel {
                    inWindow = bp.webView.window != nil
                }
                return ControlSurfaceHealthEntry(
                    surfaceID: panel.id,
                    typeRawValue: panel.panelType.rawValue,
                    inWindow: inWindow
                )
            }
            return ControlSurfaceHealthSnapshot(
                workspaceID: dock.workspaceId,
                windowID: dockResultWindowId(for: dock, tabManager: tabManager),
                surfaces: items
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let items: [ControlSurfaceHealthEntry] = controlSurfacePanels(workspace: ws).map { panel in
            var inWindow: Bool?
            if let tp = panel as? TerminalPanel {
                inWindow = tp.surface.isViewInWindow
            } else if let bp = panel as? BrowserPanel {
                inWindow = bp.webView.window != nil
            }
            return ControlSurfaceHealthEntry(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                inWindow: inWindow
            )
        }
        return ControlSurfaceHealthSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: items
        )
    }

    // MARK: - focus

    /// Focuses a local browser/terminal panel through the same window,
    /// workspace, and Dock selection path used by `surface.focus`.
    @discardableResult
    func focusLocalPanel(panelID: UUID, preferredWorkspaceID: UUID) -> Bool {
        guard let appDelegate = AppDelegate.shared else { return false }
        if let windowDock = appDelegate.windowDockContainingPanel(panelID) {
            guard let owningTabManager = appDelegate.tabManagerFor(
                windowId: windowDock.workspaceId
            ) ?? tabManager else { return false }
            return focusWindowDockPanel(
                panelID: panelID,
                in: windowDock,
                fallback: owningTabManager
            )
        }
        if let owner = appDelegate.workspaceContainingPanel(
            panelId: panelID,
            preferredWorkspaceId: preferredWorkspaceID
        ) {
            return focusLocalPanel(
                panelID: panelID,
                in: owner.workspace,
                tabManager: owner.tabManager
            )
        }
        guard let owningTabManager = appDelegate.tabManagerFor(tabId: preferredWorkspaceID),
              let workspace = owningTabManager.tabs.first(where: { $0.id == preferredWorkspaceID }),
              workspace.containsDockPanel(panelID) else { return false }
        return focusLocalPanel(
            panelID: panelID,
            in: workspace,
            tabManager: owningTabManager
        )
    }

    @discardableResult
    private func focusWindowDockPanel(
        panelID: UUID,
        in dock: DockSplitStore,
        fallback tabManager: TabManager
    ) -> Bool {
        guard dock.containsPanel(panelID) else { return false }
        focusAndRevealWindowDock(for: dock, fallback: tabManager)
        dock.focusPanel(panelID)
        return true
    }

    @discardableResult
    private func focusLocalPanel(
        panelID: UUID,
        in workspace: Workspace,
        tabManager: TabManager
    ) -> Bool {
        if let windowID = AppDelegate.shared?.windowId(for: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowID)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        if workspace.panels[panelID] != nil {
            workspace.focusPanel(panelID)
            return true
        }
        guard workspace.containsDockPanel(panelID) else { return false }
        revealDockForFocus(tabManager: tabManager)
        workspace.dockSplit.focusPanel(panelID)
        return true
    }

    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let windowDock = windowDockContainingPanel(surfaceID) {
            // An explicit window_id or Dock-owner workspace_id naming a
            // different window's Dock fails closed.
            if windowDockMismatchesExplicitSelectors(routing, dock: windowDock, aliasTabManager: tabManager) {
                return .surfaceNotFound(surfaceID)
            }
            guard focusWindowDockPanel(
                panelID: surfaceID,
                in: windowDock,
                fallback: tabManager
            ) else {
                return .surfaceNotFound(surfaceID)
            }
            return .focused(
                windowID: windowDock.workspaceId,
                workspaceID: windowDock.workspaceId,
                surfaceID: surfaceID
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        switch ws.remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
        case .pane(let location):
            guard focusRemoteTmuxControlPane(
                location,
                workspace: ws,
                tabManager: tabManager
            ) else {
                return .surfaceNotFound(surfaceID)
            }
            return .focused(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: ws.id,
                surfaceID: location.pane.panel.id
            )
        case .unresolvedMirror:
            return .surfaceNotFound(surfaceID)
        case .notRemote:
            break
        }
        guard focusLocalPanel(panelID: surfaceID, in: ws, tabManager: tabManager) else {
            return .surfaceNotFound(surfaceID)
        }
        return .focused(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceID
        )
    }
}
