public import AppKit
import CmuxNextActions

/// Joins the actions shared by all hosts to the clicked host's own sidebar menu.
@MainActor public enum SidebarMachineMenu {
    public static func inserting(_ shared: NSMenu, into menu: NSMenu, topLevelLimit: Int) -> NSMenu {
        let items = shared.items
        shared.removeAllItems()
        guard !items.isEmpty else { return menu }
        // Customize Menu… ends every menu and is not one of its rows (topLevelLimit counts rows).
        if menu.items.filter({ !$0.isSeparatorItem && !ActionRegistry.isCustomizeItem($0) }).count >= topLevelLimit,
           let options = menu.items.first(where: { $0.title == MenuFolder.options.title })?.submenu {
            options.addItem(.separator())
            for item in items { options.addItem(item) }
            return menu
        }
        var at = menu.items.firstIndex(where: \.isSeparatorItem) ?? menu.items.count
        if at > 0 {
            menu.insertItem(.separator(), at: at)
            at += 1
        }
        for item in items {
            menu.insertItem(item, at: at)
            at += 1
        }
        if at < menu.items.count, !menu.items[at].isSeparatorItem { menu.insertItem(.separator(), at: at) }
        return menu
    }
}
