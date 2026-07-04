import AppKit

extension CmuxWebView {
    private static let browserFocusModeContextMenuItemIdentifier =
        NSUserInterfaceItemIdentifier("cmux.browserFocusMode.toggle")

    func appendBrowserFocusModeContextMenuItem(to menu: NSMenu) {
        let state = AppDelegate.shared?.browserFocusModeContextMenuState(for: self) ?? (isActive: false, canToggle: false)
        guard state.isActive || state.canToggle else { return }

        let title = state.isActive
            ? String(localized: "browser.focusMode.context.exit", defaultValue: "Exit Browser Focus Mode")
            : String(localized: "browser.focusMode.context.enter", defaultValue: "Enter Browser Focus Mode")
        if let item = menu.items.first(where: { $0.identifier == Self.browserFocusModeContextMenuItemIdentifier }) {
            item.title = title
            item.target = self
            item.action = #selector(contextMenuToggleBrowserFocusMode(_:))
            item.state = state.isActive ? NSControl.StateValue.on : NSControl.StateValue.off
            return
        }

        if menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: title,
            action: #selector(contextMenuToggleBrowserFocusMode(_:)),
            keyEquivalent: ""
        )
        item.identifier = Self.browserFocusModeContextMenuItemIdentifier
        item.target = self
        item.state = state.isActive ? NSControl.StateValue.on : NSControl.StateValue.off
        menu.addItem(item)
    }

    @objc func contextMenuToggleBrowserFocusMode(_ sender: Any?) {
        _ = sender
        if AppDelegate.shared?.toggleBrowserFocusModeFromContextMenu(for: self) != true {
            NSSound.beep()
        }
    }
}
