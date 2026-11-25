public import AppKit

extension ActionRegistry {
    /// The tab bar's empty-area menu (`ActionMenuContext.tabStrip`; the strip's or the vertical list's;
    /// Edge's and Chrome's vertical-tab menus): New Tab, Reopen Closed Tab, Bookmark All Tabs, Move All
    /// Tabs to a New Workspace; the vertical tabs rows; Task Manager. Then More: the kinds of new tab
    /// (New) and the pane's menu with its own More inlined, titled as the pane's menu titles them, so
    /// nothing the strip's empty area offered before is lost.
    public func makeTabStripMenu(target: ActionTargetRef, machineID: String? = nil) -> NSMenu {
        let catalog = ContextMenuCatalog.shared
        let menu = makeContextMenu(for: .tabStrip, target: target, machineID: machineID)
        let pane = catalog.entries(for: .pane).flatMap { entry -> [ContextMenuEntry] in
            guard case .folder(.more, let children) = entry else { return [entry] }
            return [.separator] + children + [.separator]
        }
        let more = makeContextMenu(for: .pane, target: target,
                                   entries: [.folder(.new, catalog.entries(for: .newTab)), .separator] + pane,
                                   machineID: machineID)
        guard !more.items.isEmpty else { return menu }
        let item = NSMenuItem(title: MenuFolder.more.title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: MenuFolder.more.symbol, accessibilityDescription: nil)
        item.image?.isTemplate = true
        more.title = item.title
        item.submenu = more
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item)
        return menu
    }
}
