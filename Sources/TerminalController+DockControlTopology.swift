import Bonsplit
import CmuxControlSocket
import Foundation
import GhosttyKit

@MainActor
extension TerminalController {
    /// Returns the Dock containers that contribute to a workspace-scoped
    /// topology snapshot. The workspace Dock is owned by the workspace; the
    /// global Dock is owned by the workspace's window. Neither lookup creates a
    /// Dock merely because a read-only list command ran.
    func controlTopologyDocks(
        workspace: Workspace,
        tabManager: TabManager,
        includeGlobalDock: Bool = true
    ) -> [DockSplitStore] {
        var docks: [DockSplitStore] = []
        if let workspaceDock = workspace._dockSplit {
            docks.append(workspaceDock)
        }
        if includeGlobalDock,
           let globalDock = AppDelegate.shared?.existingWindowDock(for: tabManager) {
            docks.append(globalDock)
        }
        return docks
    }

    func controlDockSurfaceList(
        dock: DockSplitStore,
        tabManager: TabManager
    ) -> ControlSurfaceListSnapshot {
        ControlSurfaceListSnapshot(
            workspaceID: dock.workspaceId,
            windowID: dockResultWindowId(for: dock, tabManager: tabManager),
            surfaces: controlDockSurfaceSummaries(dock: dock)
        )
    }

    func controlDockSurfaceSummaries(dock: DockSplitStore) -> [ControlSurfaceSummary] {
        var paneByPanelID: [UUID: UUID] = [:]
        var indexInPaneByPanelID: [UUID: Int] = [:]
        var selectedInPaneByPanelID: [UUID: Bool] = [:]
        var titleByPanelID: [UUID: String] = [:]
        for paneID in dock.bonsplitController.allPaneIds {
            let tabs = dock.bonsplitController.tabs(inPane: paneID)
            let selected = dock.bonsplitController.selectedTab(inPane: paneID)
            for (index, tab) in tabs.enumerated() {
                guard let panel = dock.panel(for: tab.id) else { continue }
                paneByPanelID[panel.id] = paneID.id
                indexInPaneByPanelID[panel.id] = index
                selectedInPaneByPanelID[panel.id] = tab.id == selected?.id
                titleByPanelID[panel.id] = tab.title
            }
        }

        return orderedPanels(in: dock).map { panel in
            let terminal = panel as? TerminalPanel
            return ControlSurfaceSummary(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                title: titleByPanelID[panel.id] ?? panel.displayTitle,
                isFocused: panel.id == dock.focusedPanelId,
                paneID: paneByPanelID[panel.id],
                indexInPane: indexInPaneByPanelID[panel.id],
                selectedInPane: selectedInPaneByPanelID[panel.id],
                developerToolsVisible: (panel as? BrowserPanel)?.isDeveloperToolsVisible(),
                requestedWorkingDirectory: terminal.flatMap {
                    v2NonEmptyString($0.requestedWorkingDirectory)
                },
                initialCommand: terminal.flatMap {
                    v2NonEmptyString($0.surface.debugInitialCommand())
                },
                tmuxStartCommand: terminal.flatMap {
                    v2NonEmptyString($0.surface.debugTmuxStartCommand())
                },
                isTerminal: terminal != nil,
                resumeBinding: controlResumeBinding(
                    from: dock.surfaceResumeBinding(panelId: panel.id)
                ),
                dockScopeRawValue: dock.scope.rawValue
            )
        }
    }

    func controlDockPaneList(
        dock: DockSplitStore,
        tabManager: TabManager
    ) -> ControlPaneListSnapshot {
        let snapshot = dock.bonsplitController.layoutSnapshot()
        return ControlPaneListSnapshot(
            workspaceID: dock.workspaceId,
            windowID: dockResultWindowId(for: dock, tabManager: tabManager),
            panes: controlDockPaneSummaries(dock: dock, snapshot: snapshot),
            containerWidth: snapshot.containerFrame.width,
            containerHeight: snapshot.containerFrame.height
        )
    }

    func controlDockPaneSummaries(
        dock: DockSplitStore,
        snapshot: LayoutSnapshot? = nil,
        includePixelFrames: Bool = true
    ) -> [ControlPaneSummary] {
        let snapshot = snapshot ?? dock.bonsplitController.layoutSnapshot()
        let focusedPaneID = dock.bonsplitController.focusedPaneId
        let geometryByPaneID = Dictionary(
            snapshot.panes.map { ($0.paneId, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )

        return dock.bonsplitController.allPaneIds.map { paneID in
            let tabs = dock.bonsplitController.tabs(inPane: paneID)
            let surfaceIDs = tabs.compactMap { dock.panel(for: $0.id)?.id }
            let selectedSurfaceID = dock.bonsplitController
                .selectedTab(inPane: paneID)
                .flatMap { dock.panel(for: $0.id)?.id }
            let pixelFrame = includePixelFrames ? geometryByPaneID[paneID.id.uuidString].map {
                ControlPanePixelFrame(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            } : nil
            let gridSize = selectedSurfaceID
                .flatMap { dock.panels[$0] as? TerminalPanel }
                .flatMap { controlDockGridSize(panel: $0) }

            return ControlPaneSummary(
                paneID: paneID.id,
                isFocused: paneID == focusedPaneID,
                surfaceIDs: surfaceIDs,
                selectedSurfaceID: selectedSurfaceID,
                pixelFrame: pixelFrame,
                gridSize: gridSize,
                dockScopeRawValue: dock.scope.rawValue
            )
        }
    }

    func controlDockPaneSurfaces(
        dock: DockSplitStore,
        paneID requestedPaneID: UUID?,
        tabManager: TabManager
    ) -> ControlPaneSurfacesSnapshot? {
        let paneID: PaneID?
        if let requestedPaneID {
            paneID = dock.bonsplitController.allPaneIds.first { $0.id == requestedPaneID }
        } else {
            paneID = dock.bonsplitController.focusedPaneId
        }
        guard let paneID else { return nil }

        let selectedTab = dock.bonsplitController.selectedTab(inPane: paneID)
        let surfaces = dock.bonsplitController.tabs(inPane: paneID).map { tab in
            let panel = dock.panel(for: tab.id)
            return ControlPaneSurfaceSummary(
                surfaceID: panel?.id,
                title: tab.title,
                typeRawValue: panel?.panelType.rawValue,
                isSelected: tab.id == selectedTab?.id,
                dockScopeRawValue: dock.scope.rawValue
            )
        }

        return ControlPaneSurfacesSnapshot(
            workspaceID: dock.workspaceId,
            paneID: paneID.id,
            windowID: dockResultWindowId(for: dock, tabManager: tabManager),
            surfaces: surfaces,
            dockScopeRawValue: dock.scope.rawValue
        )
    }

    private func controlDockGridSize(panel: TerminalPanel) -> ControlPaneGridSize? {
        guard panel.surface.hasLiveSurface,
              let ghosttySurface = panel.surface.surface else {
            return nil
        }
        let size = ghostty_surface_size(ghosttySurface)
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
}
