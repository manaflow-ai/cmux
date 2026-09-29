import AppKit

/// Builds the tab context menu. Every item sends one `TabStripIntent`.
enum TabContextMenu {
    static func menu(for tab: TabItem, in model: TabStripModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let ordered = model.orderedTabs
        let index = ordered.firstIndex { $0.id == tab.id } ?? 0
        let id = tab.id

        menu.addItem(item(Strings.menuNewTab, model, .newTab(after: id)))
        menu.addItem(.separator())
        menu.addItem(item(Strings.menuClose, model, .close(id, source: .contextMenu)))
        let others = item(Strings.menuCloseOthers, model, .closeOthers(keeping: id))
        others.isEnabled = ordered.contains { $0.id != id && !$0.isPinned }
        menu.addItem(others)
        let right = item(Strings.menuCloseToRight, model, .closeToRight(of: id))
        right.isEnabled = index < ordered.count - 1
        menu.addItem(right)
        menu.addItem(.separator())
        menu.addItem(item(tab.isPinned ? Strings.menuUnpin : Strings.menuPin, model, tab.isPinned ? .unpin(id) : .pin(id)))
        menu.addItem(item(Strings.menuRename, model, .rename(id)))
        menu.addItem(item(Strings.menuDuplicate, model, .duplicate(id)))
        menu.addItem(.separator())
        menu.addItem(item(Strings.menuSplitRight, model, .moveToNewSplit(id, .right)))
        menu.addItem(item(Strings.menuSplitDown, model, .moveToNewSplit(id, .down)))
        menu.addItem(item(Strings.menuNewColumn, model, .moveToNewColumn(id)))
        return menu
    }

    static func emptySpaceMenu(in model: TabStripModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(Strings.menuNewTab, model, .newTab(after: nil)))
        return menu
    }

    private static func item(_ title: String, _ model: TabStripModel, _ intent: TabStripIntent) -> NSMenuItem {
        let action = IntentAction(intent: intent, model: model)
        let item = NSMenuItem(title: title, action: #selector(IntentAction.fire(_:)), keyEquivalent: "")
        // `target` is weak; `representedObject` keeps the action alive with the item.
        item.target = action
        item.representedObject = action
        return item
    }
}

private final class IntentAction: NSObject {
    private let intent: TabStripIntent
    private weak var model: TabStripModel?

    init(intent: TabStripIntent, model: TabStripModel) {
        self.intent = intent
        self.model = model
    }

    @objc func fire(_ sender: Any?) {
        model?.send(intent)
    }
}
