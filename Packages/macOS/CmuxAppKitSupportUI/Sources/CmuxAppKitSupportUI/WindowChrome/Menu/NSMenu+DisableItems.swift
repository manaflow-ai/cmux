public import AppKit

extension NSMenu {
    /// Recursively clears the key equivalent and disables every item in this
    /// menu tree whose `action` matches `action`, descending into submenus.
    ///
    /// Used to neutralize a native AppKit menu shortcut (for example
    /// `NSWindow.toggleTabBar(_:)`) so the app can own that key chord. Each
    /// matching item has its `keyEquivalent` cleared, its
    /// `keyEquivalentModifierMask` emptied, and `isEnabled` set to `false`.
    public func disableItems(matching action: Selector) {
        for item in items {
            if item.action == action {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                submenu.disableItems(matching: action)
            }
        }
    }
}
