public import AppKit
import CmuxNextActions

/// Joins the actions shared by all hosts to the clicked host's own sidebar menu.
extension NSMenu {
    public func insertingSharedMachineActions(_ shared: NSMenu, topLevelLimit: Int) -> NSMenu {
        let items = shared.items
        shared.removeAllItems()
        guard !items.isEmpty else { return self }
        // Customize Menu… ends every menu and is not one of its rows (topLevelLimit counts rows).
        if self.items.filter({ !$0.isSeparatorItem && !ActionRegistry.isCustomizeItem($0) }).count >= topLevelLimit,
           let options = self.items.first(where: { $0.title == MenuFolder.options.title })?.submenu {
            options.addItem(.separator())
            for item in items { options.addItem(item) }
            return self
        }
        var at = self.items.firstIndex(where: \.isSeparatorItem) ?? self.items.count
        if at > 0 {
            insertItem(.separator(), at: at)
            at += 1
        }
        for item in items {
            insertItem(item, at: at)
            at += 1
        }
        if at < self.items.count, !self.items[at].isSeparatorItem { insertItem(.separator(), at: at) }
        return self
    }
}
