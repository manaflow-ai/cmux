import AppKit
import CmuxNextDesign

/// Debug menu > Status Icons (DEV and NIGHTLY, `DevTools`; cx-kxa2): one
/// item per `StatusIconSet` candidate, with its blocked-question mark and a
/// check on the current one. Choosing writes the Debug Settings tunable, so
/// every indicator restyles at once and the choice persists in the build's
/// debug-tunables.json. Choosing the default removes the override.
final class StatusIconSetMenu: NSObject, NSMenuDelegate {
    static let shared = StatusIconSetMenu()

    /// Where the choice is written (tests pass their own store).
    var store: TunableStore = .shared

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: Strings.menuStatusIcons, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: Strings.menuStatusIcons)
        menu.delegate = self
        for set in StatusIconSet.allCases {
            let choice = NSMenuItem(title: set.tunableTitle, action: #selector(choose(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = set.rawValue
            choice.image = set.image(state: .waiting(kind: .question), pointSize: Metrics.smallIconSize)
            menu.addItem(choice)
        }
        item.submenu = menu
        updateStates(in: menu)
        return item
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let set = StatusIconSet(rawValue: raw) else { return }
        select(set)
    }

    /// Sets the icon set; the default clears the override.
    func select(_ set: StatusIconSet) {
        let key = StatusIconSet.tunable.key
        if set == StatusIconSet.tunable.defaultValue {
            store.reset([key])
        } else {
            store.set(key, set.tunableValue)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStates(in: menu)
    }

    private func updateStates(in menu: NSMenu) {
        let current = StatusIconSet.tunable.value(in: store).rawValue
        for item in menu.items {
            item.state = (item.representedObject as? String) == current ? .on : .off
        }
    }
}
