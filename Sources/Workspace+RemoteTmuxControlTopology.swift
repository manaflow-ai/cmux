import Bonsplit
import Foundation

@MainActor
extension Workspace {
    typealias RemoteTmuxControlPaneLocation = (
        containerPanelID: UUID,
        mirror: RemoteTmuxWindowMirror,
        pane: RemoteTmuxControlPane
    )
    typealias ControlSurfaceProjection = (
        surfaceID: UUID,
        paneID: UUID?,
        panel: any Panel
    )

    func remoteTmuxControlPane(paneID: UUID) -> RemoteTmuxControlPaneLocation? {
        for (containerPanelID, mirror) in remoteTmuxWindowMirrors {
            if let pane = mirror.controlPane(paneID: paneID) {
                return (containerPanelID, mirror, pane)
            }
        }
        return nil
    }

    func remoteTmuxControlPane(surfaceID: UUID) -> RemoteTmuxControlPaneLocation? {
        for (containerPanelID, mirror) in remoteTmuxWindowMirrors {
            if let pane = mirror.controlPane(surfaceID: surfaceID) {
                return (containerPanelID, mirror, pane)
            }
        }
        return nil
    }

    /// Resolves either an advertised inner surface or its hidden mirror
    /// container to the same authoritative active-pane location.
    func remoteTmuxControlTarget(surfaceID: UUID) -> RemoteTmuxControlPaneLocation? {
        if let location = remoteTmuxControlPane(surfaceID: surfaceID) {
            return location
        }
        guard let mirror = remoteTmuxWindowMirror(forPanelId: surfaceID),
              let pane = mirror.activeControlPane() else { return nil }
        return (surfaceID, mirror, pane)
    }

    /// Resolves an explicit control-plane surface without making mirror-owned
    /// panels members of the workspace's mutable `panels` collection.
    func controlTerminalPanel(for surfaceID: UUID) -> TerminalPanel? {
        terminalPanel(for: surfaceID) ?? remoteTmuxControlPane(surfaceID: surfaceID)?.pane.panel
    }

    /// Projects a workspace-owned panel into the identity exposed by the
    /// control plane. A mirror container resolves only when tmux has published
    /// an authoritative active pane; ordinary panels keep their Bonsplit pane.
    func controlSurfaceProjection(
        forContainerPanelID containerPanelID: UUID
    ) -> ControlSurfaceProjection? {
        if let mirror = remoteTmuxWindowMirror(forPanelId: containerPanelID) {
            guard let active = mirror.activeControlPane() else { return nil }
            return (active.panel.id, active.paneID.id, active.panel)
        }
        guard let panel = panels[containerPanelID] else { return nil }
        return (containerPanelID, paneId(forPanelId: containerPanelID)?.id, panel)
    }

    /// Resolves the selected terminal target. A mirror container projects its
    /// active inner pane; a requested pane projects that pane's selected surface.
    func controlDefaultTerminalTarget(
        paneID requestedPaneID: UUID?
    ) -> (surfaceID: UUID, panel: TerminalPanel)? {
        if let requestedPaneID {
            if let remote = remoteTmuxControlPane(paneID: requestedPaneID) {
                return (remote.pane.panel.id, remote.pane.panel)
            }
            if let paneID = bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID }),
               let tab = bonsplitController.selectedTab(inPane: paneID),
               let panelID = panelIdFromSurfaceId(tab.id),
               remoteTmuxWindowMirror(forPanelId: panelID) == nil,
               let panel = terminalPanel(for: panelID) {
                return (panelID, panel)
            }
            return nil
        }

        guard let focusedPanelId,
              let projection = controlSurfaceProjection(forContainerPanelID: focusedPanelId),
              let panel = projection.panel as? TerminalPanel else { return nil }
        return (projection.surfaceID, panel)
    }
}
