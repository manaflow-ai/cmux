import Foundation
import CmuxRemoteSession

@MainActor
extension RemoteTmuxSessionMirror {
    /// Creates or reconciles the in-tab multi-pane renderer. The workspace's
    /// display panel remains the stable outer container; every tmux pane gets a
    /// distinct mirror-owned panel so portal and focus ownership never span both
    /// hierarchy levels.
    func reconcileWindowMirror(
        windowId: Int,
        panelId: UUID,
        window: RemoteTmuxWindow,
        in workspace: Workspace
    ) {
        if let mirror = windowMirrorByWindowId[windowId] {
            mirror.apply(window: window)
            for paneId in window.paneIDsInOrder {
                if let cwd = cwdByPane[paneId] { mirror.updatePaneCwd(paneId: paneId, path: cwd) }
            }
            return
        }
        guard window.paneIDsInOrder.count > 1 else { return }
        let mirror = RemoteTmuxWindowMirror(
            windowId: windowId,
            panelId: panelId,
            connection: connection,
            layout: window.layout,
            appearance: workspace.bonsplitController.configuration.appearance,
            workspaceBonsplitController: workspace.bonsplitController,
            controlPaneID: { [weak self] in self?.controlPaneID(forPane: $0) },
            onControlSurfaceChanged: { [weak self] tmuxPaneID, surfaceID in
                self?.updateControlSurface(
                    tmuxPaneID: tmuxPaneID,
                    surfaceID: surfaceID,
                    windowID: windowId
                )
            },
            onPaneSurfaceProgress: { [weak self] paneId in
                self?.handlePaneSeedSurfaceProgress(paneId: paneId)
            },
            makePanel: { [weak workspace, weak connection] tmuxPaneId in
                workspace?.makeRemoteTmuxPanePanel(onInput: { data in
                    Task { @MainActor in connection?.sendKeys(paneId: tmuxPaneId, data: data) }
                })
            }
        )
        mirror.onClosePaneRequest = { [weak workspace, weak mirror] tmuxPaneId in
            guard let mirror else { return }
            workspace?.requestRemoteTmuxPaneClose(windowMirror: mirror, tmuxPaneId: tmuxPaneId)
        }
        mirror.onEstablishPaneKeyFocus = { [weak mirror] paneId, panel in
            RemoteTmuxWindowMirror.establishPaneKeyFocusWhenMounted(
                paneId: paneId, panel: panel, mirror: mirror
            )
        }
        // The window can already be zoomed when its first topology publish
        // arrives; apply the full update after seeding the base tree.
        mirror.apply(window: window)
        windowMirrorByWindowId[windowId] = mirror
        workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: panelId)
        for paneId in window.paneIDsInOrder where panelIdByPane[paneId] == panelId {
            panelIdByPane[paneId] = nil
        }
        if let panel = workspace.panels[panelId] as? TerminalPanel {
            panel.surface.onManualSizeApplied = nil
            panel.surface.onRuntimeReady = nil
        }
    }
}
