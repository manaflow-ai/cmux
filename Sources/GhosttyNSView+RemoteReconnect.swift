import AppKit

extension GhosttyNSView {
    func appendReconnectRemotePaneMenuItem(to menu: NSMenu) {
        guard let workspace = remoteWorkspaceForCurrentSurface(),
              remotePaneReconnectAction(in: workspace) != nil else { return }
        menu.addItem(.separator())
        let item = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.reconnectPane", defaultValue: "Reconnect Pane"),
            action: #selector(reconnectRemotePane(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
    }

    private func remoteWorkspaceForCurrentSurface() -> Workspace? {
        guard let tabId,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == tabId }),
              workspace.isRemoteWorkspace else {
            return nil
        }
        return workspace
    }

    /// What Reconnect Pane would do for the current surface.
    private enum RemotePaneReconnectAction {
        /// Respawn through the shared persistent-reattach path.
        case reattach(UUID)
        /// Answer a dead non-persistent wrapper's own retry prompt.
        case promptRetry(TerminalPanel)
    }

    /// Resolves appearance and behavior from one place so they cannot diverge.
    private func remotePaneReconnectAction(in workspace: Workspace) -> RemotePaneReconnectAction? {
        guard let surfaceId = terminalSurface?.id,
              let panel = workspace.panels[surfaceId] as? TerminalPanel else { return nil }
        if workspace.remoteConfiguration?.preserveAfterTerminalExit == true {
            // Persistent sessions may be reattached while the wrapper is still alive:
            // respawn HUPs the wrapper, which retires only its lifecycle generation.
            return workspace.canReattachRemoteTerminalSurface(surfaceId) ? .reattach(surfaceId) : nil
        }
        guard workspace.remoteDisconnectPlaceholderPanelIds.contains(surfaceId)
                || workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(surfaceId) else {
            return nil
        }
        switch workspace.remoteConnectionState {
        case .connecting, .reconnecting:
            return nil
        case .connected, .disconnected, .suspended, .error:
            // The keystroke fallback is only ever reachable for a dead wrapper sitting
            // at its own prompt; the preserveAfterTerminalExit split guarantees a live
            // pane never lands here.
            return .promptRetry(panel)
        }
    }

    @objc private func reconnectRemotePane(_ sender: Any?) {
        guard let workspace = remoteWorkspaceForCurrentSurface(),
              let action = remotePaneReconnectAction(in: workspace) else { return }
        switch action {
        case .reattach(let surfaceId):
            workspace.reconnectRemoteConnection(surfaceId: surfaceId)
        case .promptRetry(let panel):
            panel.sendInput("r\r")
        }
    }
}
