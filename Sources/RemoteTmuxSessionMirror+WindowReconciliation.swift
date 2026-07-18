import Foundation
import CmuxRemoteSession

@MainActor
extension RemoteTmuxSessionMirror {
    /// Creates or reconciles the in-tab multi-pane renderer. A surviving
    /// single-pane display transfers only its panel; control identity remains
    /// owned by the session-wide pane ledger.
    func reconcileWindowMirror(
        windowId: Int,
        panelId: UUID,
        window: RemoteTmuxWindow,
        displayPanelWasCreated: Bool,
        in workspace: Workspace
    ) {
        if let mirror = windowMirrorByWindowId[windowId] {
            mirror.apply(window: window)
            for paneId in window.paneIDsInOrder {
                if let cwd = cwdByPane[paneId] { mirror.updatePaneCwd(paneId: paneId, path: cwd) }
            }
            return
        }
        let registry = workspace.terminalClientComposition.remoteTmuxSurfaceRegistry
        guard window.paneIDsInOrder.count > 1
                || registry?.requiresNestedPresentation(
                    workspaceID: workspace.id,
                    tmuxWindowID: windowId
                ) == true else { return }
        let adoptedPanes: [RemoteTmuxWindowMirror.AdoptedPane] = window.paneIDsInOrder.compactMap {
            tmuxPaneId in
            guard (!displayPanelWasCreated || registry != nil),
                  panelIdByPane[tmuxPaneId] == panelId,
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
            makePanel: { [weak self, weak workspace, weak connection] tmuxPaneId in
                let currentWindow = connection?.windowsByID[windowId]
                let leaf = currentWindow?.layout.leavesByPaneID[tmuxPaneId]
                return workspace?.makeRemoteTmuxPanePanel(
                    remotePaneId: tmuxPaneId,
                    initialColumns: leaf?.width ?? currentWindow?.width ?? 80,
                    initialRows: leaf?.height ?? currentWindow?.height ?? 24,
                    onInput: { data in
                        Task { @MainActor in
                            connection?.sendKeys(paneId: tmuxPaneId, data: data)
                        }
                    },
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
        for adoptedPane in adoptedPanes {
            panelIdByPane[adoptedPane.tmuxPaneId] = nil
        }
        if displayPanelWasCreated, let firstPaneID = window.paneIDsInOrder.first {
            panelIdByPane[firstPaneID] = nil
        }
        if adoptedPanes.isEmpty, let panel = workspace.panels[panelId] as? TerminalPanel {
            panel.surface.onManualSizeApplied = nil
            panel.surface.onRuntimeReady = nil
        }
    }
}
