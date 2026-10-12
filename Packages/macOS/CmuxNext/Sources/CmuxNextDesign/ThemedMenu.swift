public import AppKit

extension NSMenu {
    /// Draws this menu's rows, and its submenus', in `scope`'s accent instead of the system accent
    /// (follow-up to #19754). NSMenu always highlights in the system accent and only follows light
    /// and dark, so every row becomes a `ThemedMenuRowView` that draws its own highlight in
    /// `Palette.accentFill` with `Palette.onAccent` ink. Separators and rows that already have a
    /// view (the workspace color swatches) are left as they are. Call it last, once the menu is
    /// built, with the scope of the view that was right-clicked.
    ///
    /// The items keep their titles, key equivalents, states and submenus, so type-select, arrow
    /// keys and submenus work as before. Their action goes through a `ThemedMenuDispatch`, which
    /// runs it once however it arrives: AppKit's Return or key equivalent, a click on the row
    /// (AppKit sends no action for a click on a view row), or Return delivered to the row.
    @discardableResult
    public func themeRows(in scope: ThemeScope) -> NSMenu {
        appearance = scope.appearance
        themeRows(in: scope, session: ThemedMenuSession())
        return self
    }

    private func themeRows(in scope: ThemeScope, session: ThemedMenuSession) {
        for item in items where !item.isSeparatorItem {
            if item.view == nil { item.view = ThemedMenuRowView(item: item, scope: scope, session: session) }
            if let submenu = item.submenu {
                submenu.appearance = scope.appearance
                submenu.themeRows(in: scope, session: session)
            }
        }
    }
}

/// One opening of a themed menu, shared by its submenus: its action runs at most once.
final class ThemedMenuSession {
    private(set) var hasRun = false

    /// The menu (re)opened: its rows may run again.
    func reset() { hasRun = false }

    /// Runs `body` unless something in this opening already ran.
    func runOnce(_ body: () -> Void) {
        guard !hasRun else { return }
        hasRun = true
        body()
    }
}

/// A themed row's item target: sends the item's own action to its own target once per opening,
/// and validates through that target, so a disabled action stays disabled.
final class ThemedMenuDispatch: NSObject, NSMenuItemValidation {
    private weak var target: AnyObject?
    private let action: Selector
    private let session: ThemedMenuSession

    init(target: AnyObject?, action: Selector, session: ThemedMenuSession) {
        self.target = target
        self.action = action
        self.session = session
    }

    @objc func run(_ sender: NSMenuItem) {
        session.runOnce { _ = NSApplication.shared.sendAction(action, to: target, from: sender) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let receiver: AnyObject? = target ?? (NSApplication.shared.target(forAction: action, to: nil, from: menuItem) as? NSObject)
        guard let receiver else { return false }
        return (receiver as? any NSMenuItemValidation)?.validateMenuItem(menuItem) ?? true
    }
}
