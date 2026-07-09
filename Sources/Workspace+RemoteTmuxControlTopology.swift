import Bonsplit
import Foundation

@MainActor
extension Workspace {
    typealias RemoteTmuxControlPaneLocation = (
        containerPanelID: UUID,
        mirror: RemoteTmuxWindowMirror,
        pane: RemoteTmuxControlPane
    )

    /// The inner panes of the selected mirrored tmux window, or an empty list
    /// when the selected surface is not a multi-pane mirror container.
    func selectedRemoteTmuxControlPanes() -> [RemoteTmuxControlPane] {
        guard let focusedPanelId,
              let mirror = remoteTmuxWindowMirror(forPanelId: focusedPanelId) else {
            return []
        }
        return mirror.controlPanes()
    }

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

    /// Resolves an explicit control-plane surface without making mirror-owned
    /// panels members of the workspace's mutable `panels` collection.
    func controlTerminalPanel(for surfaceID: UUID) -> TerminalPanel? {
        terminalPanel(for: surfaceID) ?? remoteTmuxControlPane(surfaceID: surfaceID)?.pane.panel
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
               let panelID = panelIdFromSurfaceId(tab.id) {
                if let mirror = remoteTmuxWindowMirror(forPanelId: panelID),
                   let active = mirror.activeControlPane() {
                    return (active.panel.id, active.panel)
                }
                if let panel = terminalPanel(for: panelID) {
                    return (panelID, panel)
                }
            }
            return nil
        }

        guard let focusedPanelId else { return nil }
        if let mirror = remoteTmuxWindowMirror(forPanelId: focusedPanelId),
           let active = mirror.activeControlPane() {
            return (active.panel.id, active.panel)
        }
        guard let panel = terminalPanel(for: focusedPanelId) else { return nil }
        return (focusedPanelId, panel)
    }
}
