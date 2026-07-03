import AppKit

extension GhosttyNSView {
    func appendReconnectRemotePaneMenuItem(to menu: NSMenu) {
        guard remoteWorkspaceForCurrentSurface() != nil else { return }
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

    @objc private func reconnectRemotePane(_ sender: Any?) {
        guard let workspace = remoteWorkspaceForCurrentSurface(),
              let surfaceId = terminalSurface?.id else { return }
        workspace.reconnectRemoteConnection(surfaceId: surfaceId)
    }
}
