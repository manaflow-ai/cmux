public import AppKit

extension NSMenu {
    /// Draws this menu's rows, and its submenus', in `scope`'s accent instead of the system accent
    /// (follow-up to #19754). NSMenu always highlights in the system accent and only follows light
    /// and dark, so every row becomes a `ThemedMenuRowView` that draws its own highlight: a faint
    /// wash of the theme's accent (`Palette.menuHighlight`) in the label's ink. Separators, section headers and rows that already have a
    /// view (the workspace and group menus' name and color header) are left as they are; such a view that is a
    /// `ThemedMenuItemView` is handed the scope to draw in. Call it last, once the menu is
    /// built, with the scope of the view that was right-clicked.
    ///
    /// The items keep their titles, key equivalents, states and submenus, so type-select, arrow
    /// keys and submenus work as before. Their action goes through a `ThemedMenuDispatch`, which
    /// runs it once however it arrives: AppKit's Return or key equivalent, a click on the row
    /// (AppKit sends no action for a click on a view row), or Return delivered to the row.
    ///
    /// A chosen row runs once the menu's tracking loop has ended, except the rows `runsInPlace`
    /// picks: those run as the menu closes, as a native row does. That is for an engine's own
    /// items (WebKit's Copy, Look Up, Inspect Element), whose target forgets the menu once the
    /// engine's `popUp` returns, so a later run would do nothing.
    @discardableResult
    public func themeRows(in scope: ThemeScope, runsInPlace: @escaping @MainActor (NSMenuItem) -> Bool = { _ in false }) -> NSMenu {
        appearance = scope.appearance
        themeRows(in: scope, session: ThemedMenuSession(runsInPlace: runsInPlace))
        return self
    }

    fileprivate func themeRows(in scope: ThemeScope, session: ThemedMenuSession) {
        // Arrow keys move the highlight without AppKit redrawing view rows: the relay does, and
        // passes every call on to the delegate the menu had (a choices submenu's coordinator).
        if !(delegate is ThemedMenuHighlightRelay) {
            let relay = ThemedMenuHighlightRelay(forward: delegate, scope: scope, session: session)
            session.keep(relay)
            delegate = relay
        }
        // A section header ("Phones" in the device menu) stays AppKit's: it never highlights or runs.
        for item in items where !item.isSeparatorItem && !item.isSectionHeader {
            if let view = item.view as? any ThemedMenuItemView {
                view.adoptMenuScope(scope)
            } else if item.view == nil {
                item.view = ThemedMenuRowView(item: item, scope: scope, session: session)
            }
            if let submenu = item.submenu {
                submenu.appearance = scope.appearance
                submenu.themeRows(in: scope, session: session)
            }
        }
    }
}

extension NSMenu {
    /// Themes rows added to this themed menu since it was themed (a search's results while it is
    /// open), in its scope and opening; does nothing in a menu that was never themed.
    public func themeAddedRows() {
        (delegate as? ThemedMenuHighlightRelay)?.themeRows(of: self)
    }

    /// Runs `body` once a row chosen in this themed menu has run. A themed row runs its item after
    /// the menu's tracking loop ends (`ThemedMenuRowView.activate`), so code that follows `popUp`
    /// and settles the menu's outcome (a page menu that ends a dismissed request) waits for it.
    /// The menu stays alive until then.
    public func afterThemedRowRuns(_ body: @escaping @MainActor () -> Void) {
        let step = ThemedMenuAfterRun { [self] in
            _ = self
            body()
        }
        RunLoop.main.perform(#selector(ThemedMenuAfterRun.run), target: step, argument: nil,
                             order: ThemedMenuRowView.pendingRunOrder + 1, modes: [.default])
    }
}

/// `afterThemedRowRuns`'s step: the run loop keeps its target until it runs.
final class ThemedMenuAfterRun: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    @objc func run() { body() }
}

/// One opening of a themed menu, shared by its submenus: its action runs at most once.
final class ThemedMenuSession {
    private(set) var hasRun = false
    /// The rows that run as the menu closes, not after its tracking loop (``NSMenu/themeRows(in:runsInPlace:)``).
    let runsInPlace: @MainActor (NSMenuItem) -> Bool
    /// A menu's delegate is weak; the rows hold the session, the session holds the relays.
    private var relays: [ThemedMenuHighlightRelay] = []

    init(runsInPlace: @escaping @MainActor (NSMenuItem) -> Bool = { _ in false }) {
        self.runsInPlace = runsInPlace
    }

    func keep(_ relay: ThemedMenuHighlightRelay) { relays.append(relay) }

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

/// A themed menu's delegate: redraws the row losing and the row taking the highlight, then
/// forwards to the menu's previous delegate, which keeps its own behavior.
final class ThemedMenuHighlightRelay: NSObject, NSMenuDelegate {
    private weak var forward: (any NSMenuDelegate)?
    private let scope: ThemeScope
    /// The session keeps this relay, so it outlives it; weak only to make no cycle.
    private weak var session: ThemedMenuSession?

    init(forward: (any NSMenuDelegate)?, scope: ThemeScope, session: ThemedMenuSession) {
        self.forward = forward
        self.scope = scope
        self.session = session
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for row in [menu.highlightedItem?.view, item?.view] {
            if let row = row as? ThemedMenuRowView { row.highlightChanged() } else { row?.needsDisplay = true }
        }
        forward?.menu?(menu, willHighlight: item)
    }

    func menuWillOpen(_ menu: NSMenu) { forward?.menuWillOpen?(menu) }
    func menuDidClose(_ menu: NSMenu) { forward?.menuDidClose?(menu) }
    /// A submenu filled as it opens (Open With ▸) themes the rows its delegate just added.
    func menuNeedsUpdate(_ menu: NSMenu) {
        forward?.menuNeedsUpdate?(menu)
        themeRows(of: menu)
    }

    /// Themes `menu`'s rows that are not yet themed, in this relay's scope and opening.
    func themeRows(of menu: NSMenu) {
        if let session { menu.themeRows(in: scope, session: session) }
    }
}
