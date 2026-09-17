import AppKit
import CmuxTextActions

/// Payload for a Snippets context-menu item: the right-clicked panel and the
/// text action to insert into it. Boxed so `NSMenuItem.representedObject`
/// can carry it, matching the saved-layout and fork menus.
private final class SnippetContextMenuActionBox: NSObject {
    let panelId: UUID
    let actionID: String

    init(panelId: UUID, actionID: String) {
        self.panelId = panelId
        self.actionID = actionID
    }
}

extension GhosttyNSView {
    /// Appends "Snippets ▸" to the terminal context menu: uncategorised
    /// `type: "text"` actions first, then one sub-submenu per `category`.
    /// Adds nothing and returns false when the config defines no text actions.
    /// Rebuilt on every right-click, so config reloads need no refresh hook.
    @discardableResult
    func appendSnippetsContextMenuItems(to menu: NSMenu) -> Bool {
        guard let panelId = terminalSurface?.id,
              let store = snippetContextMenuConfigStore(panelId: panelId) else {
            return false
        }
        let model = store.snippetMenuModel()
        guard !model.isEmpty else { return false }

        let snippetsItem = NSMenuItem(
            title: String(localized: "terminalContextMenu.snippets", defaultValue: "Snippets"),
            action: nil,
            keyEquivalent: ""
        )
        snippetsItem.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
        let submenu = NSMenu()
        for item in model.uncategorized {
            submenu.addItem(makeSnippetMenuItem(item, panelId: panelId))
        }
        if !model.uncategorized.isEmpty, !model.categories.isEmpty {
            submenu.addItem(.separator())
        }
        for category in model.categories {
            let categoryItem = NSMenuItem(title: category.name, action: nil, keyEquivalent: "")
            categoryItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let categoryMenu = NSMenu()
            for item in category.items {
                categoryMenu.addItem(makeSnippetMenuItem(item, panelId: panelId))
            }
            categoryItem.submenu = categoryMenu
            submenu.addItem(categoryItem)
        }
        snippetsItem.submenu = submenu
        menu.addItem(snippetsItem)
        return true
    }

    /// One leaf item; the box carries the clicked panel and the action id so
    /// the handler can re-resolve both from authoritative state.
    private func makeSnippetMenuItem(_ item: CmuxSnippetMenuItem, panelId: UUID) -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: item.title,
            action: #selector(insertSnippetFromContextMenu(_:)),
            keyEquivalent: ""
        )
        menuItem.target = self
        menuItem.representedObject = SnippetContextMenuActionBox(panelId: panelId, actionID: item.actionID)
        if item.payload.submit {
            // Visual hint that choosing this one presses Enter as well.
            menuItem.image = NSImage(systemSymbolName: "return", accessibilityDescription: nil)
        }
        return menuItem
    }

    /// The config store owned by the window that owns the clicked panel.
    /// Fails closed (no menu, no insertion) when that ownership cannot be
    /// established, rather than guessing from another window's store.
    private func snippetContextMenuConfigStore(panelId: UUID) -> CmuxConfigStore? {
        guard let delegate = AppDelegate.shared,
              let located = delegate.workspaceContainingPanel(panelId: panelId) else {
            return nil
        }
        return delegate.mainWindowContext(for: located.tabManager)?.cmuxConfigStore
    }

    /// Inserts the chosen snippet into the panel that was right-clicked, not
    /// whichever panel happens to be focused. Submitting snippets go through
    /// the same project-trust gate as the palette and shortcut paths.
    @objc func insertSnippetFromContextMenu(_ sender: Any?) {
        guard let box = (sender as? NSMenuItem)?.representedObject as? SnippetContextMenuActionBox,
              let delegate = AppDelegate.shared,
              let located = delegate.workspaceContainingPanel(panelId: box.panelId),
              let panel = located.workspace.panels[box.panelId] as? TerminalPanel,
              let store = snippetContextMenuConfigStore(panelId: box.panelId),
              let action = store.resolvedAction(id: box.actionID),
              let payload = action.action.textPayload else {
            NSSound.beep()
            return
        }
        _ = CmuxConfigExecutor.deliverTextActionIfAuthorized(
            payload,
            confirm: action.confirm ?? false,
            actionID: action.id,
            configSourcePath: action.actionSourcePath,
            globalConfigPath: store.globalConfigPath,
            displayTitle: action.title,
            icon: action.icon,
            iconSourcePath: action.iconSourcePath,
            presentingWindow: window
        ) {
            CmuxConfigExecutor.deliver(payload, to: panel)
        }
    }
}
