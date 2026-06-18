import AppKit
import CmuxWorkspaceNavigation

private let focusHistoryContextMenuPreviewLimit = 12

private final class FocusHistoryContextMenuItemBox: NSObject {
    weak var tabManager: TabManager?
    let item: FocusHistoryMenuItem

    init(tabManager: TabManager, item: FocusHistoryMenuItem) {
        self.tabManager = tabManager
        self.item = item
    }
}

private final class FocusHistoryShowFullContextMenuBox: NSObject {
    weak var tabManager: TabManager?
    weak var anchorView: NSView?
    let direction: FocusHistoryMenuDirection

    init(tabManager: TabManager, anchorView: NSView, direction: FocusHistoryMenuDirection) {
        self.tabManager = tabManager
        self.anchorView = anchorView
        self.direction = direction
    }
}

extension AppDelegate {
    @discardableResult
    func showFocusHistoryContextMenu(
        anchorView: NSView,
        event: NSEvent,
        direction: FocusHistoryMenuDirection,
        showFullHistory: Bool = false,
        debugSource: String = "titlebar.focusHistory.contextMenu"
    ) -> Bool {
        let context = contextForMainWindow(anchorView.window)
            ?? mainWindowContext(forShortcutEvent: event, debugSource: debugSource)
        guard let context else { return false }

        let menu = makeFocusHistoryContextMenu(
            tabManager: context.tabManager,
            anchorView: anchorView,
            direction: direction,
            showFullHistory: showFullHistory
        )
        guard menu.items.contains(where: { !$0.isSeparatorItem }) else { return false }

        NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
        return true
    }

    private func makeFocusHistoryContextMenu(
        tabManager: TabManager,
        anchorView: NSView,
        direction: FocusHistoryMenuDirection,
        showFullHistory: Bool
    ) -> NSMenu {
        let snapshot = tabManager.focusHistoryMenuSnapshot(
            direction: direction,
            maxItemCount: showFullHistory ? nil : focusHistoryContextMenuPreviewLimit
        )
        let menu = NSMenu(title: String(localized: "menu.history.focusHistory", defaultValue: "Focus History"))

        if snapshot.items.isEmpty {
            let item = NSMenuItem(
                title: String(localized: "menu.history.noFocusHistory", defaultValue: "No Focus History"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        for itemSnapshot in snapshot.items {
            let item = NSMenuItem(
                title: focusHistoryContextMenuTitle(for: itemSnapshot),
                action: #selector(performFocusHistoryContextMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = FocusHistoryContextMenuItemBox(tabManager: tabManager, item: itemSnapshot)
            item.isEnabled = itemSnapshot.isNavigable
            menu.addItem(item)
        }

        if snapshot.isLimited {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: String(localized: "menu.history.showFullFocusHistory", defaultValue: "Show Full History"),
                action: #selector(showFullFocusHistoryContextMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = FocusHistoryShowFullContextMenuBox(
                tabManager: tabManager,
                anchorView: anchorView,
                direction: direction
            )
            menu.addItem(item)
        }

        return menu
    }

    private func focusHistoryContextMenuTitle(for item: FocusHistoryMenuItem) -> String {
        FocusHistoryMenuFormatter.title(for: item)
    }

    @objc private func performFocusHistoryContextMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? FocusHistoryContextMenuItemBox,
              let tabManager = box.tabManager,
              tabManager.navigateToFocusHistoryMenuItem(box.item) else {
            NSSound.beep()
            return
        }
    }

    @objc private func showFullFocusHistoryContextMenu(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? FocusHistoryShowFullContextMenuBox,
              let tabManager = box.tabManager,
              let anchorView = box.anchorView else {
            NSSound.beep()
            return
        }

        let menu = makeFocusHistoryContextMenu(
            tabManager: tabManager,
            anchorView: anchorView,
            direction: box.direction,
            showFullHistory: true
        )
        guard menu.items.contains(where: { !$0.isSeparatorItem }) else {
            NSSound.beep()
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
    }
}
