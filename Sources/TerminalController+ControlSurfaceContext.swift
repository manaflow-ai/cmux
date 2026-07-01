import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import GhosttyKit

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
            guard windowDockContainingPanel(surfaceId) == nil else { return nil }
            return tabManager.tabs.first(where: { $0.containsDockPanel(surfaceId) })
        }
        if let paneId = routing.paneID {
            if let located = v2LocatePane(paneId) {
                guard located.tabManager === tabManager else { return nil }
                return located.workspace
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

        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]
        for paneId in ws.bonsplitController.allPaneIds {
            let tabs = ws.bonsplitController.tabs(inPane: paneId)
            let selected = ws.bonsplitController.selectedTab(inPane: paneId)
            for (idx, tab) in tabs.enumerated() {
                guard let panelId = ws.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelId[panelId] = paneId.id
                indexInPaneByPanelId[panelId] = idx
                selectedInPaneByPanelId[panelId] = (tab.id == selected?.id)
            }
        }

        let focusedSurfaceId = ws.focusedPanelId
        let surfaces: [ControlSurfaceSummary] = orderedPanels(in: ws).map { panel in
            let terminalPanel = panel as? TerminalPanel
            return ControlSurfaceSummary(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                title: ws.panelTitle(panelId: panel.id) ?? panel.displayTitle,
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
                resumeBinding: terminalPanel != nil
                    ? controlResumeBinding(from: ws.surfaceResumeBinding(panelId: panel.id))
                    : nil
            )
        }

        return ControlSurfaceListSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: surfaces
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
            windowID: v2ResolveWindowId(tabManager: tabManager),
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
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: dock.workspaceId,
                paneID: paneId,
                surfaceID: surfaceId,
                surfaceTypeRawValue: surfaceId.flatMap { dock.panels[$0]?.panelType.rawValue }
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let surfaceId = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
        let paneId = surfaceId.flatMap { ws.paneId(forPanelId: $0)?.id }
        return ControlSurfaceCurrentSnapshot(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: paneId,
            surfaceID: surfaceId,
            surfaceTypeRawValue: surfaceId.flatMap { ws.panels[$0]?.panelType.rawValue }
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
                windowID: v2ResolveWindowId(tabManager: tabManager),
                surfaces: items
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let items: [ControlSurfaceHealthEntry] = orderedPanels(in: ws).map { panel in
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

    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let windowDock = windowDockContainingPanel(surfaceID) {
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            revealDockForFocus(tabManager: tabManager)
            windowDock.focusPanel(surfaceID)
            return .focused(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: windowDock.workspaceId,
                surfaceID: surfaceID
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        if let windowId = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != ws.id {
            tabManager.selectWorkspace(ws)
        }
        if ws.panels[surfaceID] != nil {
            ws.focusPanel(surfaceID)
        } else if ws.containsDockPanel(surfaceID) {
            revealDockForFocus(tabManager: tabManager)
            ws.dockSplit.focusPanel(surfaceID)
        } else {
            return .surfaceNotFound(surfaceID)
        }
        return .focused(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceID
        )
    }
}
