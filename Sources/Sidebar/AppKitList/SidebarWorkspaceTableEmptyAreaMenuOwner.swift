import AppKit

/// Owns the empty workspace-table area's menu target and capability state.
@MainActor
final class SidebarWorkspaceTableEmptyAreaMenuOwner: NSObject {
    private var actions: SidebarWorkspaceTableActions?

    func createEmptyWorkspaceGroup(actions: SidebarWorkspaceTableActions?) {
        guard actions?.canCreateEmptyWorkspaceGroup == true else { return }
        actions?.createEmptyWorkspaceGroup()
    }

    func menu(actions: SidebarWorkspaceTableActions?) -> NSMenu {
        self.actions = actions
        let menu = NSMenu()
        let item = NSMenuItem(
            title: String(
                localized: "contextMenu.workspaceGroup.newEmpty",
                defaultValue: "New Empty Workspace Group"
            ),
            action: #selector(createEmptyWorkspaceGroupFromMenu),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = actions?.canCreateEmptyWorkspaceGroup == true
        let shortcut = KeyboardShortcutSettings.shortcut(for: .newWorkspaceGroup)
        if let keyEquivalent = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        menu.addItem(item)
        return menu
    }

    @objc private func createEmptyWorkspaceGroupFromMenu() {
        createEmptyWorkspaceGroup(actions: actions)
    }
}
