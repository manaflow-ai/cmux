import AppKit

extension GhosttyNSView {
    func appendReconnectRemotePaneMenuItem(to menu: NSMenu) {
        guard let workspace = remoteWorkspaceForCurrentSurface(),
              canReconnectRemotePane(in: workspace),
              remoteReconnectablePanel(in: workspace) != nil else { return }
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

    private func canReconnectRemotePane(in workspace: Workspace) -> Bool {
        switch workspace.remoteConnectionState {
        case .connected, .disconnected, .suspended, .error:
            return true
        case .connecting, .reconnecting:
            return false
        }
    }

    private func remoteReconnectablePanel(in workspace: Workspace) -> TerminalPanel? {
        guard let surfaceId = terminalSurface?.id,
              workspace.remoteDisconnectPlaceholderPanelIds.contains(surfaceId) ||
                  workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(surfaceId),
              let panel = workspace.panels[surfaceId] as? TerminalPanel else { return nil }
        return panel
    }

    @objc private func reconnectRemotePane(_ sender: Any?) {
        guard let workspace = remoteWorkspaceForCurrentSurface(),
              canReconnectRemotePane(in: workspace),
              let panel = remoteReconnectablePanel(in: workspace) else { return }
        if workspace.remoteConfiguration?.preserveAfterTerminalExit == true,
           workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id) ||
           workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id) {
            workspace.reconnectRemoteConnection(surfaceId: panel.id)
            return
        }
        panel.sendInput("r\r")
    }
}
