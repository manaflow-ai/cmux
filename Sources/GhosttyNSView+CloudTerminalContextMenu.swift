import AppKit

/// "Detach Terminal" / "Kill Process" on a pane that projects a cloud terminal:
/// the same two verbs the tab context menu offers, on the same workspace path.
extension GhosttyNSView {
    func appendCloudTerminalContextMenuItems(to menu: NSMenu) {
        guard let context = cloudTerminalPaneContext(),
              context.workspace.cloudTerminalPane(forPanel: context.panelId) != nil else { return }
        menu.addItem(.separator())
        let detachItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.detachCloudTerminal", defaultValue: "Detach Terminal"),
            action: #selector(detachCloudTerminalPane(_:)),
            keyEquivalent: ""
        )
        detachItem.target = self
        detachItem.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: nil)
        let killItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.killCloudTerminal", defaultValue: "Kill Process"),
            action: #selector(killCloudTerminalPane(_:)),
            keyEquivalent: ""
        )
        killItem.target = self
        killItem.image = NSImage(systemSymbolName: "xmark.octagon", accessibilityDescription: nil)
    }

    private func cloudTerminalPaneContext() -> (workspace: Workspace, panelId: UUID)? {
        guard let tabId,
              let panelId = terminalSurface?.id,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == tabId }) else { return nil }
        return (workspace, panelId)
    }

    @objc private func detachCloudTerminalPane(_ sender: Any?) {
        guard let context = cloudTerminalPaneContext() else { return }
        context.workspace.detachCloudTerminal(panelId: context.panelId)
    }

    @objc private func killCloudTerminalPane(_ sender: Any?) {
        guard let context = cloudTerminalPaneContext() else { return }
        context.workspace.killCloudTerminal(panelId: context.panelId)
    }
}
