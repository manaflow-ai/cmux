import Bonsplit
import CmuxFoundation
import CmuxRemoteSession
import Foundation
import Observation

@MainActor
extension RemoteTmuxWindowMirror {
    func observePaneColors() {
        let center = NotificationCenter.default
        paneColorObserverTokens.append(center.addObserver(
            forName: .ghosttySurfaceThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let surfaceId = notification.object as? UUID else { return }
            MainActor.assumeIsolated {
                guard let self, !self.isTornDown else { return }
                for (paneId, panel) in self.panelsByPaneId where panel.surface.id == surfaceId {
                    self.schedulePaneColorRefresh(paneId: paneId)
                }
            }
        })
        paneColorObserverTokens.append(center.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isTornDown else { return }
                for paneId in self.panelsByPaneId.keys {
                    self.schedulePaneColorRefresh(paneId: paneId)
                }
            }
        })
    }

    private func schedulePaneColorRefresh(paneId: Int) {
        guard pendingPaneColorRefreshes.insert(paneId).inserted else { return }
        // Defer the snapshot until Ghostty releases its renderer lock, and
        // coalesce a burst of palette notifications for the same surface.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingPaneColorRefreshes.remove(paneId)
            self.reportPaneColors(paneId: paneId)
        }
    }

    func removePaneColorsIfOwned(paneId: Int) {
        guard (connection?.publishedWindowIdByPane[paneId] ?? windowId) == windowId else { return }
        connection?.removePaneColors(paneId: paneId)
    }

    func reportPaneColors(paneId: Int) {
        guard !isTornDown,
              (connection?.publishedWindowIdByPane[paneId] ?? windowId) == windowId,
              let panel = panelsByPaneId[paneId] else { return }
        let colors: RemoteTmuxPaneColors?
        if let paneColorsSource {
            colors = paneColorsSource(panel)
        } else if let frame = panel.surface.mobileRenderGridFrame(stateSeq: 0)?.frame,
                  let foreground = frame.terminalForeground,
                  let background = frame.terminalBackground {
            colors = RemoteTmuxPaneColors(foreground: foreground, background: background)
        } else {
            // Hidden panes may not have a Ghostty runtime yet. Seed the current
            // app defaults now; onRuntimeReady replaces them with surface colors.
            let app = GhosttyApp.shared
            colors = RemoteTmuxPaneColors(
                foreground: app.defaultForegroundColor.hexString(),
                background: app.defaultBackgroundColor.hexString()
            )
        }
        guard let colors else {
            connection?.record("pane-color-snapshot-invalid %\(paneId)")
            return
        }
        connection?.setPaneColors(colors, paneId: paneId)
    }

    func observeWorkspaceBonsplitConfiguration() {
        guard let source = workspaceBonsplitController else { return }
        let configuration = withObservationTracking {
            source.configuration
        } onChange: { [weak self, weak source] in
            Task { @MainActor [weak self, weak source] in
                guard let self, self.workspaceBonsplitController === source else { return }
                self.observeWorkspaceBonsplitConfiguration()
            }
        }
        applyWorkspaceBonsplitConfiguration(configuration)
    }

    func applyWorkspaceBonsplitConfiguration(_ workspaceConfiguration: BonsplitConfiguration) {
        let previousAppearance = bonsplitController.configuration.appearance
        let nextConfiguration = workspaceConfiguration.remoteTmuxEmbedded
        let nextAppearance = nextConfiguration.appearance
        let sizingChanged = previousAppearance.tabBarHeight != nextAppearance.tabBarHeight
            || previousAppearance.dividerThickness != nextAppearance.dividerThickness

        bonsplitController.configuration = nextConfiguration
        bonsplitController.tabShortcutHintsEnabled = false
        if sizingChanged {
            setNeedsSizingPassIgnoringInputs()
        }
    }
}
