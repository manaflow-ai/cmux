public import AppKit

/// Keeps AppKit's AutoFill out of a first-party page's context menu. AppKit adds it after
/// `willOpenMenu` to a menu opened while a text field has focus (the agent composer), so a
/// rebuild in `willOpenMenu` never sees it; a page is app chrome with nothing to fill. Each item
/// goes as AppKit adds it, with the separator AppKit put before it, so the menu never shows it.
/// Services and the other system items stay.
@MainActor
public final class PageMenuSystemItems {
    private var observer: (any NSObjectProtocol)?

    nonisolated public init() {}

    /// AppKit's AutoFill title (its own localized item); the English title where AppKit has none.
    static let autoFillTitle: String = {
        // crash-allow: AppKit private class method, called only after responds(to:) confirms it (no unknown-selector exception).
        let selector = NSSelectorFromString("_standardAutoFillMenuItem")
        let menuItemClass: AnyObject = NSMenuItem.self
        guard menuItemClass.responds(to: selector),
              let item = menuItemClass.perform(selector)?.takeUnretainedValue() as? NSMenuItem,
              !item.title.isEmpty else { return "AutoFill" }
        return item.title
    }()

    /// Call at the end of `willOpenMenu`, once the menu holds the page's items.
    public func watch(_ menu: NSMenu) {
        stop()
        let own = menu.numberOfItems
        // queue: nil runs the block inline, as AppKit adds the item, before the menu draws.
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: menu, queue: nil) { note in
            MainActor.assumeIsolated { // main-proof: AppKit adds menu items on main
                guard let menu = note.object as? NSMenu, let index = note.userInfo?["NSMenuItemIndex"] as? Int else { return }
                Self.drop(at: index, from: menu, own: own)
            }
        }
    }

    /// Call from `didCloseMenu`.
    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Removes the item at `index` when it is AutoFill, and a separator AppKit added before it.
    static func drop(at index: Int, from menu: NSMenu, own: Int) {
        guard index < menu.numberOfItems, menu.item(at: index)?.title == autoFillTitle else { return }
        menu.removeItem(at: index)
        if index > own, index - 1 < menu.numberOfItems, menu.item(at: index - 1)?.isSeparatorItem == true {
            menu.removeItem(at: index - 1)
        }
    }
}
