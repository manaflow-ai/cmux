import AppKit
import Foundation

extension GhosttyNSView {
    /// Adds the Switch Claude Account submenu when the pane runs Claude on this Mac and the user
    /// registered at least two accounts.
    ///
    /// - Returns: Whether the submenu was added.
    @discardableResult
    func appendSwitchClaudeAccountMenuItems(to menu: NSMenu) -> Bool {
        guard let panelId = terminalSurface?.id,
              let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: panelId)?.workspace,
              let model = workspace.claudeAccountSwitchMenuModel(panelId: panelId) else {
            return false
        }
        menu.addItem(Self.makeSwitchClaudeAccountMenuItem(for: model, target: self))
        return true
    }

    /// The Switch Claude Account item and its submenu. Picking a row sends
    /// ``switchClaudeAccountFromContextMenu(_:)`` to `target` with the account name as the
    /// item's `representedObject`; the current account's row is checked and disabled.
    static func makeSwitchClaudeAccountMenuItem(
        for model: ClaudeAccountSwitchMenuModel,
        target: AnyObject
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "terminalContextMenu.switchClaudeAccount", defaultValue: "Switch Claude Account"),
            action: nil,
            keyEquivalent: ""
        )
        item.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        let submenu = NSMenu()
        // Enablement comes from the model, not from responder-chain validation.
        submenu.autoenablesItems = false
        for entry in model.entries {
            // Account names are user-chosen identifiers, shown as written.
            let row = NSMenuItem(
                title: entry.accountName,
                action: entry.isCurrent ? nil : #selector(switchClaudeAccountFromContextMenu(_:)),
                keyEquivalent: ""
            )
            row.target = entry.isCurrent ? nil : target
            row.representedObject = entry.accountName
            row.state = entry.isCurrent ? .on : .off
            row.isEnabled = !entry.isCurrent
            submenu.addItem(row)
        }
        item.submenu = submenu
        return item
    }

    /// Switches the clicked pane to the account named by the menu item.
    @objc func switchClaudeAccountFromContextMenu(_ sender: Any?) {
        guard let accountName = (sender as? NSMenuItem)?.representedObject as? String,
              let panelId = terminalSurface?.id,
              let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: panelId)?.workspace else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            await ClaudeAccountSwitchUserFlow().run(workspace: workspace, panelId: panelId, accountName: accountName)
        }
    }
}
