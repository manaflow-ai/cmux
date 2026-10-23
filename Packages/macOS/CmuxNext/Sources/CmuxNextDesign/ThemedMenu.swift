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
        // The rows' shared state and icon columns, measured once for the whole menu: a row's draw
        // reads no other row. Rows themed before take the new measure (a search hid the checked row).
        let columns = ThemedMenuColumns(of: self)
        // A section header ("Phones" in the device menu) stays AppKit's: it never highlights or runs.
        for item in items where !item.isSeparatorItem && !item.isSectionHeader {
            if let view = item.view as? any ThemedMenuItemView {
                view.adoptMenuScope(scope)
            } else if let row = item.view as? ThemedMenuRowView {
                row.adoptColumns(columns)
            } else if item.view == nil {
                item.view = ThemedMenuRowView(item: item, scope: scope, session: session, columns: columns)
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
        // A row chosen from the keyboard runs once the menu has closed: the step waits for it.
        if let session = (delegate as? ThemedMenuHighlightRelay)?.session, session.afterPendingRun({ [self] in _ = self; body() }) { return }
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

    /// Whether the menu is open: between its root's `menuWillOpen` and `menuDidClose`.
    private(set) var isOpen = false
    /// The chosen row's run, waiting for the menu to close.
    private var pendingRun: (@MainActor () -> Void)?
    /// `afterThemedRowRuns` steps that wait for `pendingRun`.
    private var afterRuns: [@MainActor () -> Void] = []
    /// A row was chosen and its run has not finished yet (`afterThemedRowRuns` steps wait for it).
    var awaitingRun = false

    /// The root menu opened.
    func opened() { isOpen = true }

    /// Runs `body` once the menu has closed: now when it is not open (a row run outside a
    /// tracking menu), else when its root's `menuDidClose` arrives. A row chosen while the menu
    /// still tracks must not run before then: its window still has the keys, so an action that
    /// reads the focused window or pane would act on the menu instead.
    func runWhenClosed(_ body: @escaping @MainActor () -> Void) {
        guard isOpen else { return body() }
        pendingRun = body
    }

    /// Queues `body` after the pending row's run; false when no run is pending.
    func afterPendingRun(_ body: @escaping @MainActor () -> Void) -> Bool {
        guard pendingRun != nil || awaitingRun else { return false }
        afterRuns.append(body)
        return true
    }

    /// The root menu closed: the chosen row starts its run (it calls ``finishedRun()`` after it).
    func closed() {
        isOpen = false
        let run = pendingRun
        pendingRun = nil
        // A row already running (a click) finishes its own run; else nothing was chosen.
        if let run { run() } else if !awaitingRun { finishedRun() }
    }

    /// The chosen row ran (or could not): the `afterThemedRowRuns` steps waiting for it run now.
    func finishedRun() {
        let after = afterRuns
        afterRuns = []
        after.forEach { $0() }
    }

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
    private(set) weak var session: ThemedMenuSession?

    init(forward: (any NSMenuDelegate)?, scope: ThemeScope, session: ThemedMenuSession) {
        self.forward = forward
        self.scope = scope
        self.session = session
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for row in [menu.highlightedItem?.view, item?.view] {
            if let row = row as? ThemedMenuRowView { row.highlightChanged() } else { row?.needsDisplay = true }
        }
        // The highlighted row takes the menu's keys (Return, keypad Enter, Space run it).
        if let row = item?.view as? ThemedMenuRowView {
            row.takeKeys()
        } else if item == nil {
            (menu.highlightedItem?.view as? ThemedMenuRowView)?.releaseKeys()
        }
        forward?.menu?(menu, willHighlight: item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu.supermenu == nil { session?.opened() }
        forward?.menuWillOpen?(menu)
        // A menu kept between openings may have checked or hidden rows since (its delegate may
        // have just done it): measure it once now.
        menu.refreshThemedColumns()
    }

    func menuDidClose(_ menu: NSMenu) {
        forward?.menuDidClose?(menu)
        // The root closed: a row chosen from the keyboard runs now (``ThemedMenuSession/runWhenClosed(_:)``).
        if menu.supermenu == nil { session?.closed() }
    }
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
