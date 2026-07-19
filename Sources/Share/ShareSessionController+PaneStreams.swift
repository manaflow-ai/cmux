import Foundation
import WebKit

/// Slice 2/3 wiring: pixel streaming for browser/agent panes, composer
/// co-editing for agent panes, and guest pointer/keyboard application for
/// browser panes. Routing is by pane kind; terminal panes stay on the grid
/// streamer.
extension ShareSessionController {
    func wirePaneStreamsAndComposer() {
        pixelStreamer.sendBinary = { [weak self] data in
            self?.socket?.send(data: data)
        }
        pixelStreamer.resolveWebView = { [weak self] ws, pane in
            self?.paneWebView(ws: ws, pane: pane)
        }
        composerSync.sendComposeState = { [weak self] field, rev, text, carets in
            self?.socket?.send(.composeState(field: field, rev: rev, text: text, carets: carets))
        }
        composerSync.applyTextToPane = { [weak self] field, text in
            guard let self,
                  let panelID = UUID(uuidString: field),
                  let panel = self.sharedAgentPanel(id: panelID) else { return }
            panel.rendererSession.setComposerText(text)
        }
    }

    /// Routes a `guest-sub` update to the streamer matching the pane's kind.
    /// Zero counts clear both streamers so a stale subscription never leaks
    /// when a pane's panel could not be resolved.
    func routeGuestSub(ws: String, pane: String, count: Int) {
        if count <= 0 {
            streamer.setSubscriberCount(ws: ws, pane: pane, count: 0)
            pixelStreamer.setSubscriberCount(ws: ws, pane: pane, count: 0)
            return
        }
        let panel = panePanel(ws: ws, pane: pane)
        if panel is TerminalPanel {
            streamer.setSubscriberCount(ws: ws, pane: pane, count: count)
        } else if panel is BrowserPanel || panel is AgentSessionPanel {
            pixelStreamer.setSubscriberCount(ws: ws, pane: pane, count: count)
        } else if panel == nil,
                  let surfaceID = UUID(uuidString: pane),
                  GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) != nil {
            // Terminal panes are keyed by surface UUID (== panel UUID); an
            // unresolvable pane may still be a live terminal surface.
            streamer.setSubscriberCount(ws: ws, pane: pane, count: count)
        }
    }

    // MARK: - Composer co-editing (agent panes)

    func applyGuestCompose(user: String, field: String, rev: Int, ops: [ShareComposeOp], caret: ShareCaretRange?) {
        guard participant(user)?.role == .editor,
              let panelID = UUID(uuidString: field),
              sharedAgentPanel(id: panelID) != nil else {
            return
        }
        composerSync.applyGuestOps(field: field, user: user, baseRev: rev, ops: ops, caret: caret)
    }

    /// Installs `onComposerTextChanged` hooks on every shared agent panel and
    /// removes hooks (plus canonical field state) for panels that left the
    /// shared set. Idempotent; runs from every layout sync.
    func syncComposerHooks(sharedWorkspaces: [Workspace]) {
        var liveAgentPanelIDs = Set<UUID>()
        for workspace in sharedWorkspaces {
            for panel in workspace.panels.values {
                guard let agentPanel = panel as? AgentSessionPanel else { continue }
                liveAgentPanelIDs.insert(agentPanel.id)
                guard !composerHookedPanelIDs.contains(agentPanel.id) else { continue }
                composerHookedPanelIDs.insert(agentPanel.id)
                let field = agentPanel.id.uuidString
                agentPanel.rendererSession.onComposerTextChanged = { [weak self] text in
                    self?.composerSync.hostTextChanged(field: field, text: text)
                }
            }
        }
        for panelID in composerHookedPanelIDs.subtracting(liveAgentPanelIDs) {
            composerHookedPanelIDs.remove(panelID)
            composerSync.removeField(panelID.uuidString)
            agentPanelAnywhere(id: panelID)?.rendererSession.onComposerTextChanged = nil
        }
    }

    func uninstallComposerHooks() {
        for panelID in composerHookedPanelIDs {
            agentPanelAnywhere(id: panelID)?.rendererSession.onComposerTextChanged = nil
        }
        composerHookedPanelIDs.removeAll()
    }

    // MARK: - Guest pointer/keyboard (browser panes only)

    func applyGuestPointer(_ pointer: ShareGuestPointer) {
        guard participant(pointer.user)?.role == .editor,
              let webView = sharedBrowserWebView(ws: pointer.ws, pane: pointer.pane) else {
            return
        }
        browserInput.applyPointer(pointer, to: webView)
    }

    func applyGuestWebKey(_ key: ShareGuestWebKey) {
        guard participant(key.user)?.role == .editor,
              let webView = sharedBrowserWebView(ws: key.ws, pane: key.pane) else {
            return
        }
        browserInput.applyKey(key, to: webView)
    }

    // MARK: - Resolution

    private func sharedBrowserWebView(ws: String, pane: String) -> WKWebView? {
        guard let wsUUID = UUID(uuidString: ws),
              sharedWorkspaceIDs.contains(wsUUID) else { return nil }
        return (panePanel(ws: ws, pane: pane) as? BrowserPanel)?.webView
    }

    private func panePanel(ws: String, pane: String) -> (any Panel)? {
        guard let tabManager,
              let wsUUID = UUID(uuidString: ws),
              let paneUUID = UUID(uuidString: pane),
              let workspace = tabManager.tabs.first(where: { $0.id == wsUUID }) else {
            return nil
        }
        return workspace.panels[paneUUID]
    }

    private func paneWebView(ws: String, pane: String) -> WKWebView? {
        let panel = panePanel(ws: ws, pane: pane)
        if let browser = panel as? BrowserPanel {
            return browser.webView
        }
        if let agent = panel as? AgentSessionPanel {
            return agent.rendererSession.webView
        }
        return nil
    }

    private func sharedAgentPanel(id panelID: UUID) -> AgentSessionPanel? {
        guard let tabManager else { return nil }
        for workspace in tabManager.tabs where sharedWorkspaceIDs.contains(workspace.id) {
            if let panel = workspace.panels[panelID] as? AgentSessionPanel {
                return panel
            }
        }
        return nil
    }

    private func agentPanelAnywhere(id panelID: UUID) -> AgentSessionPanel? {
        guard let tabManager else { return nil }
        for workspace in tabManager.tabs {
            if let panel = workspace.panels[panelID] as? AgentSessionPanel {
                return panel
            }
        }
        return nil
    }
}
