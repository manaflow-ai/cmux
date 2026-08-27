import AppKit

extension CmuxWebView {
    func appendMoveTabToNewWorkspaceContextMenuItem(to menu: NSMenu) {
        let title = String(localized: "browser.contextMenu.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace")
        guard contextMenuMoveTabToNewWorkspace != nil,
              contextMenuCanMoveTabToNewWorkspace?() ?? true,
              !hasMoveTabToNewWorkspaceContextMenuItem(in: menu, title: title) else {
            return
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: title,
            action: #selector(contextMenuMoveTabToNewWorkspace(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    private func hasMoveTabToNewWorkspaceContextMenuItem(in menu: NSMenu, title: String) -> Bool {
        menu.items.contains { item in
            item.action == #selector(contextMenuMoveTabToNewWorkspace(_:)) || item.title == title
        }
    }

    @objc func contextMenuMoveTabToNewWorkspace(_ sender: Any?) {
        _ = sender
        guard contextMenuMoveTabToNewWorkspace?() == true else {
            NSSound.beep()
            return
        }
    }
}
