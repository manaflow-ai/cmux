import Foundation
import CmuxRemoteSession

@MainActor
extension RemoteTmuxSessionMirror {
    /// Creates or reconciles the in-tab renderer. The workspace's display panel
    /// remains the stable outer container from the first one-pane layout, while
    /// every tmux pane gets a distinct mirror-owned panel. A later split therefore
    /// extends the existing mirror without replacing the original pane or its
    /// scrollback.
    func reconcileWindowMirror(
        windowId: Int,
        panelId: UUID,
        window: RemoteTmuxWindow,
        in workspace: Workspace
    ) {
        if let mirror = windowMirrorByWindowId[windowId] {
            let wasEmptyBeforeReconcile = mirror.panelsByPaneId.isEmpty
            mirror.apply(window: window)
            for paneId in window.paneIDsInOrder {
                if let cwd = cwdByPane[paneId] { mirror.updatePaneCwd(paneId: paneId, path: cwd) }
            }
            retireContainerPanelIfNeeded(
                panelId: panelId,
                mirror: mirror,
                wasEmptyBeforeReconcile: wasEmptyBeforeReconcile,
                in: workspace
            )
            return
        }
        let adoptedPanes: [RemoteTmuxWindowMirror.AdoptedPane] = window.paneIDsInOrder.compactMap {
            tmuxPaneId in
            guard persistentOuterPanelIdByPane[tmuxPaneId] == panelId,
                  let panel = workspace.panels[panelId] as? TerminalPanel else { return nil }
            return (tmuxPaneId, panel)
        }
        let mirror = RemoteTmuxWindowMirror(
            windowId: windowId,
            panelId: panelId,
            connection: connection,
            layout: window.layout,
            appearance: workspace.bonsplitController.configuration.appearance,
            workspaceBonsplitController: workspace.bonsplitController,
            controlPaneID: { [weak self] in self?.controlPaneID(forPane: $0) },
            onControlSurfaceChanged: { [weak self] tmuxPaneID, surfaceID in
                if surfaceID == nil, let workspace = self?.workspace {
                    workspace.terminalClientComposition.remoteTmuxSurfaceRegistry?
                        .retireIfNested(workspaceID: workspace.id, tmuxPaneID: tmuxPaneID)
                }
                self?.updateControlSurface(
                    tmuxPaneID: tmuxPaneID,
                    surfaceID: surfaceID,
                    windowID: windowId
                )
            },
            adoptedPanes: adoptedPanes,
            onPaneSurfaceProgress: { [weak self] paneId in
                self?.handlePaneSeedSurfaceProgress(paneId: paneId)
            },
            makePanel: { [weak self, weak workspace, weak connection] tmuxPaneId in
                guard let self,
                      let onInput = self.makePaneInputHandler(toPane: tmuxPaneId) else {
                    return nil
                }
                let currentWindow = connection?.windowsByID[windowId]
                let leaf = currentWindow?.layout.leavesByPaneID[tmuxPaneId]
                return workspace?.makeRemoteTmuxPanePanel(
                    remotePaneId: tmuxPaneId,
                    initialColumns: leaf?.width ?? currentWindow?.width ?? 80,
                    initialRows: leaf?.height ?? currentWindow?.height ?? 24,
                    onInput: onInput,
                    keyNameResolver: { RemoteTmuxKeyName(inputEvent: $0)?.value },
                    backendSendKeys: { [weak connection] data in
                        connection?.sendKeys(paneId: tmuxPaneId, data: data) ?? false
                    },
                    onRequestSeed: { [weak connection] in
                        connection?.seedPane(paneId: tmuxPaneId)
                    },
                    backendProvenance: self?.backendProvenance(
                        windowID: windowId,
                        paneID: tmuxPaneId,
                        role: .nestedPane
                    )
                )
            }
        )
        mirror.onClosePaneRequest = { [weak workspace, weak mirror] tmuxPaneId in
            guard let mirror else { return }
            workspace?.requestRemoteTmuxPaneClose(windowMirror: mirror, tmuxPaneId: tmuxPaneId)
        }
        // The window can already be zoomed when its first topology publish
        // arrives; apply the full update after seeding the base tree.
        mirror.apply(window: window)
        windowMirrorByWindowId[windowId] = mirror
        workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: panelId)
        for adoptedPane in adoptedPanes {
            persistentOuterPanelIdByPane[adoptedPane.tmuxPaneId] = nil
        }
        retireContainerPanelIfNeeded(
            panelId: panelId,
            mirror: mirror,
            wasEmptyBeforeReconcile: true,
            in: workspace
        )
    }

    /// Retires the wrapper only on the transition from no pane content to live
    /// pane content. If panel creation fails, the wrapper remains visible and a
    /// later topology reconciliation can retry without leaving a blank tab.
    private func retireContainerPanelIfNeeded(
        panelId: UUID,
        mirror: RemoteTmuxWindowMirror,
        wasEmptyBeforeReconcile: Bool,
        in workspace: Workspace
    ) {
        guard wasEmptyBeforeReconcile,
              !mirror.panelsByPaneId.isEmpty,
              !mirror.panelsByPaneId.values.contains(where: { $0.id == panelId }),
              let panel = workspace.panels[panelId] as? TerminalPanel else { return }
        panel.surface.onManualSizeApplied = nil
        panel.surface.onRuntimeReady = nil
        // The panel remains the stable window container, but its terminal
        // is no longer rendered or routed once the inner mirror exists.
        GhosttyApp.terminalSurfaceRegistry.unregister(panel.surface)
        panel.close()
    }
}
