import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import GhosttyKit

@MainActor
extension TerminalController {
    func controlTabManager(surfaceID: UUID) -> TabManager? {
        AppDelegate.shared?.locateSurface(surfaceId: surfaceID)?.tabManager
            ?? locateDockSurface(surfaceID)?.tabManager
            ?? locateRemoteTmuxControlSurface(surfaceID)?.tabManager
    }

    func controlTabManager(paneID: UUID) -> TabManager? {
        v2LocatePane(paneID)?.tabManager
            ?? locateDockPane(paneID)?.tabManager
            ?? locateRemoteTmuxControlPane(paneID)?.tabManager
    }

    func locateRemoteTmuxControlSurface(
        _ surfaceID: UUID
    ) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let tabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            if let workspace = tabManager.tabs.first(where: {
                $0.remoteTmuxControlPane(surfaceID: surfaceID) != nil
            }) {
                return (summary.windowId, workspace.id, tabManager)
            }
        }
        return nil
    }

    func locateRemoteTmuxControlPane(
        _ paneID: UUID
    ) -> (windowId: UUID, tabManager: TabManager, workspace: Workspace, paneId: PaneID)? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let tabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for workspace in tabManager.tabs {
                guard let location = workspace.remoteTmuxControlPane(paneID: paneID) else { continue }
                return (summary.windowId, tabManager, workspace, location.pane.paneID)
            }
        }
        return nil
    }

    func locateRemoteTmuxMirrorContainer(
        _ surfaceID: UUID
    ) -> (windowId: UUID, tabManager: TabManager, workspace: Workspace)? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let tabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            if let workspace = tabManager.tabs.first(where: {
                $0.isRemoteTmuxControlContainer(surfaceID)
            }) {
                return (summary.windowId, tabManager, workspace)
            }
        }
        return nil
    }

    func remoteTmuxMirrorContainerID(in params: [String: JSONValue]) -> UUID? {
        for key in ["surface_id", "before_surface_id", "after_surface_id"] {
            guard let rawID = params[key]?.foundationObject as? String,
                  let surfaceID = UUID(uuidString: rawID) else { continue }
            if locateRemoteTmuxMirrorContainer(surfaceID) != nil { return surfaceID }
        }
        return nil
    }

    /// Reorders the workspace-owned tab behind a control-plane surface. Remote
    /// pane surfaces project to their tmux-window container, while the response
    /// preserves the advertised surface identity supplied by the caller.
    func controlSurfaceReorder(
        surfaceID: UUID,
        inputs: ControlSurfaceReorderInputs,
        requestedFocus: Bool
    ) -> ControlSurfaceReorderResolution {
        let focus = v2FocusAllowed(requested: requestedFocus)
        guard let tabManager = controlTabManager(surfaceID: surfaceID),
              let ws = tabManager.tabs.first(where: {
                  $0.controlReorderContainerPanelID(for: surfaceID) != nil
              }),
              let sourcePanelID = ws.controlReorderContainerPanelID(for: surfaceID),
              let sourcePane = ws.paneId(forPanelId: sourcePanelID),
              let windowID = v2ResolveWindowId(tabManager: tabManager) else {
            return .surfaceNotFound(surfaceID)
        }

        let targetIndex: Int
        if let index = inputs.index {
            targetIndex = index
        } else if let beforeSurfaceID = inputs.beforeSurfaceID {
            guard let anchorPanelID = ws.controlReorderContainerPanelID(for: beforeSurfaceID),
                  let anchorPane = ws.paneId(forPanelId: anchorPanelID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: anchorPanelID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex
        } else if let afterSurfaceID = inputs.afterSurfaceID {
            guard let anchorPanelID = ws.controlReorderContainerPanelID(for: afterSurfaceID),
                  let anchorPane = ws.paneId(forPanelId: anchorPanelID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: anchorPanelID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex + 1
        } else {
            return .reorderFailed
        }

        guard ws.reorderSurface(panelId: sourcePanelID, toIndex: targetIndex, focus: focus) else {
            return .reorderFailed
        }
        return .reordered(
            windowID: windowID,
            workspaceID: ws.id,
            paneID: sourcePane.id,
            surfaceID: surfaceID
        )
    }

    func controlPaneList(
        workspace: Workspace,
        tabManager: TabManager
    ) -> ControlPaneListSnapshot {
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        return ControlPaneListSnapshot(
            workspaceID: workspace.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            panes: controlPaneSummaries(workspace: workspace, snapshot: snapshot),
            containerWidth: snapshot.containerFrame.width,
            containerHeight: snapshot.containerFrame.height
        )
    }

    func controlPaneSummaries(
        workspace: Workspace,
        snapshot: LayoutSnapshot
    ) -> [ControlPaneSummary] {
        let focusedPaneId = workspace.bonsplitController.focusedPaneId
        let geometryByPaneId = Dictionary(
            snapshot.panes.map { ($0.paneId, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
        return workspace.bonsplitController.allPaneIds.flatMap { paneID -> [ControlPaneSummary] in
            let tabs = workspace.bonsplitController.tabs(inPane: paneID)
            let panelIDs = tabs.compactMap { workspace.panelIdFromSurfaceId($0.id) }
            let selectedPanelID = workspace.bonsplitController
                .selectedTab(inPane: paneID)
                .flatMap { workspace.panelIdFromSurfaceId($0.id) }
            let frame = geometryByPaneId[paneID.id.uuidString].map {
                ControlPanePixelFrame(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }

            var summaries = panelIDs.flatMap { containerPanelID -> [ControlPaneSummary] in
                workspace.remoteTmuxControlPanes(containerPanelID: containerPanelID).map { location in
                    let pane = location.pane
                    return ControlPaneSummary(
                        paneID: pane.paneID.id,
                        isFocused: workspace.focusedPanelId == containerPanelID && pane.isFocused,
                        surfaceIDs: [pane.panel.id],
                        selectedSurfaceID: pane.panel.id,
                        pixelFrame: nil,
                        gridSize: controlGridSize(panel: pane.panel)
                    )
                }
            }

            let standardSurfaceIDs = panelIDs.filter {
                !workspace.isRemoteTmuxControlContainer($0)
            }
            guard !standardSurfaceIDs.isEmpty else { return summaries }
            let selectedStandardSurfaceID = selectedPanelID.flatMap { panelID in
                workspace.isRemoteTmuxControlContainer(panelID) ? nil : panelID
            }
            summaries.append(ControlPaneSummary(
                paneID: paneID.id,
                isFocused: paneID == focusedPaneId && selectedStandardSurfaceID != nil,
                surfaceIDs: standardSurfaceIDs,
                selectedSurfaceID: selectedStandardSurfaceID,
                pixelFrame: frame,
                gridSize: selectedStandardSurfaceID
                    .flatMap { workspace.terminalPanel(for: $0) }
                    .flatMap { controlGridSize(panel: $0) }
            ))
            return summaries
        }
    }

    private func controlGridSize(panel: TerminalPanel) -> ControlPaneGridSize? {
        guard panel.surface.hasLiveSurface, let surface = panel.surface.surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }
        let cellPoints = panel.surface.cellSizePoints()
        return ControlPaneGridSize(
            columns: Int(size.columns),
            rows: Int(size.rows),
            cellWidthPx: Int(size.cell_width_px),
            cellHeightPx: Int(size.cell_height_px),
            cellWidthPoints: cellPoints.map { Double($0.width) },
            cellHeightPoints: cellPoints.map { Double($0.height) }
        )
    }

    func controlPaneSurfaces(
        workspace: Workspace,
        paneID requestedPaneID: UUID?,
        tabManager: TabManager
    ) -> ControlPaneSurfacesSnapshot? {
        let remoteLocation = requestedPaneID.flatMap { workspace.remoteTmuxControlPane(paneID: $0) }
        let remotePane: RemoteTmuxControlPane?
        if let remoteLocation {
            remotePane = remoteLocation.pane
        } else if requestedPaneID == nil,
                  let focusedPanelID = workspace.focusedPanelId,
                  workspace.isRemoteTmuxControlContainer(focusedPanelID) {
            guard let activePane = workspace.activeRemoteTmuxControlPane(
                containerPanelID: focusedPanelID
            ) else { return nil }
            remotePane = activePane.pane
        } else {
            remotePane = nil
        }
        if let remotePane {
            return ControlPaneSurfacesSnapshot(
                workspaceID: workspace.id,
                paneID: remotePane.paneID.id,
                windowID: v2ResolveWindowId(tabManager: tabManager),
                surfaces: [ControlPaneSurfaceSummary(
                    surfaceID: remotePane.panel.id,
                    title: remotePane.title,
                    typeRawValue: remotePane.panel.panelType.rawValue,
                    isSelected: true
                )]
            )
        }

        let paneID: PaneID?
        if let requestedPaneID {
            paneID = workspace.bonsplitController.allPaneIds.first(where: {
                $0.id == requestedPaneID
            })
        } else {
            paneID = workspace.bonsplitController.focusedPaneId
        }
        guard let paneID else { return nil }
        let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneID)
        let surfaces = workspace.bonsplitController.tabs(inPane: paneID).compactMap {
            tab -> ControlPaneSurfaceSummary? in
            guard let panelID = workspace.panelIdFromSurfaceId(tab.id),
                  !workspace.isRemoteTmuxControlContainer(panelID) else {
                return nil
            }
            let panel = workspace.panels[panelID]
            return ControlPaneSurfaceSummary(
                surfaceID: panelID,
                title: tab.title,
                typeRawValue: panel?.panelType.rawValue,
                isSelected: tab.id == selectedTab?.id
            )
        }
        guard !surfaces.isEmpty else { return nil }
        return ControlPaneSurfacesSnapshot(
            workspaceID: workspace.id,
            paneID: paneID.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: surfaces
        )
    }

    func controlPaneFocus(
        workspace: Workspace,
        paneID requestedPaneID: UUID,
        tabManager: TabManager
    ) -> ControlPaneFocusResolution {
        if let location = workspace.remoteTmuxControlPane(paneID: requestedPaneID) {
            guard focusRemoteTmuxControlPane(
                location,
                workspace: workspace,
                tabManager: tabManager
            ) else {
                return .paneNotFound(requestedPaneID)
            }
            return .focused(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: workspace.id,
                paneID: requestedPaneID
            )
        }
        guard let paneID = workspace.bonsplitController.allPaneIds.first(where: {
            $0.id == requestedPaneID
        }) else {
            return .paneNotFound(requestedPaneID)
        }
        if let windowID = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowID)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        workspace.bonsplitController.focusPane(paneID)
        return .focused(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: workspace.id,
            paneID: paneID.id
        )
    }

    func controlSurfaceSummaries(workspace: Workspace) -> [ControlSurfaceSummary] {
        var paneByPanelID: [UUID: UUID] = [:]
        var indexInPaneByPanelID: [UUID: Int] = [:]
        var selectedInPaneByPanelID: [UUID: Bool] = [:]
        for paneID in workspace.bonsplitController.allPaneIds {
            let tabs = workspace.bonsplitController.tabs(inPane: paneID)
            let selected = workspace.bonsplitController.selectedTab(inPane: paneID)
            for (index, tab) in tabs.enumerated() {
                guard let panelID = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelID[panelID] = paneID.id
                indexInPaneByPanelID[panelID] = index
                selectedInPaneByPanelID[panelID] = tab.id == selected?.id
            }
        }

        return orderedPanels(in: workspace).flatMap { panel -> [ControlSurfaceSummary] in
            if workspace.isRemoteTmuxControlContainer(panel.id) {
                return workspace.remoteTmuxControlPanes(containerPanelID: panel.id).map { location in
                    let remotePane = location.pane
                    return ControlSurfaceSummary(
                        surfaceID: remotePane.panel.id,
                        typeRawValue: remotePane.panel.panelType.rawValue,
                        title: remotePane.title,
                        isFocused: panel.id == workspace.focusedPanelId && remotePane.isFocused,
                        paneID: remotePane.paneID.id,
                        indexInPane: 0,
                        selectedInPane: true,
                        developerToolsVisible: nil,
                        requestedWorkingDirectory: v2NonEmptyString(remotePane.panel.requestedWorkingDirectory),
                        initialCommand: v2NonEmptyString(remotePane.panel.surface.debugInitialCommand()),
                        tmuxStartCommand: v2NonEmptyString(remotePane.panel.surface.debugTmuxStartCommand()),
                        isTerminal: true,
                        resumeBinding: nil
                    )
                }
            }
            let terminalPanel = panel as? TerminalPanel
            return [ControlSurfaceSummary(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                isFocused: panel.id == workspace.focusedPanelId,
                paneID: paneByPanelID[panel.id],
                indexInPane: indexInPaneByPanelID[panel.id],
                selectedInPane: selectedInPaneByPanelID[panel.id],
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
                    ? controlResumeBinding(from: workspace.surfaceResumeBinding(panelId: panel.id))
                    : nil
            )]
        }
    }

    func controlSurfacePanels(workspace: Workspace) -> [any Panel] {
        orderedPanels(in: workspace).flatMap { panel -> [any Panel] in
            if workspace.isRemoteTmuxControlContainer(panel.id) {
                return workspace.remoteTmuxControlPanes(containerPanelID: panel.id).map { $0.pane.panel }
            }
            return [panel]
        }
    }
}
