public import AppKit
import CmuxNextCompat

/// A menu cmux draws on its own glass (``GlassMenuMaterial``) from a plain `NSMenu`: the same rows,
/// actions, validation, shortcuts, checks, subtitles and submenus, drawn as the web's menus are, so a
/// native menu and a web one side by side are one material. The account menu at the sidebar's
/// bottom-left is the first (Leo, 2026-11-11: "Well, that's the whole point, right? Like that's what we
/// wanted to do anyways. have better design (systems too)"). Standard right-click menus stay `NSMenu`
/// (Lawrence's ask: right-click context menus are standard macOS menus).
///
/// The popup is a ``NativePopupPanel`` under a ``NativePopupHost`` (placement, the one-frame open and
/// the fade on close, the dismiss rules) with ``Glass/makeMenuPanel(content:cornerRadius:interactive:)``
/// as its card. Rows are ``PopupRowView``s on the menu grid (``MenuMetrics``). The pointer and the
/// keys share one highlight: Up and Down move it, Right or Return opens a submenu beside its row, Left
/// closes one layer, Escape closes the menu, Return or a click runs the row. A row runs after the menu
/// has closed, on the next turn of the run loop, as a chosen `NSMenuItem` does.
@MainActor
public final class GlassMenu {
    /// The menu being drawn; its items are read at each open (`update()` validates them first).
    public let menu: NSMenu
    /// Called once when the menu closes, whether a row ran or not.
    public var onClose: (() -> Void)?

    let panel = NativePopupPanel(identifier: "cmux.glass-menu")
    let host: NativePopupHost
    let list = GlassMenuListView()
    private let surface: OverlaySurfaceView
    private weak var parentMenu: GlassMenu?
    private var child: GlassMenu?
    private var scope: ThemeScope?
    /// The control the menu opened from: a click on it is the control's (it closes the menu
    /// itself, a toggle), not a click outside that closes and then reopens it.
    private weak var anchorView: NSView?
    private var closed = false
    /// The menu holds itself while it is open (its owner may keep no reference); closing lets go.
    private var holdsSelf: GlassMenu?

    public init(menu: NSMenu) {
        self.menu = menu
        host = NativePopupHost(panel: panel)
        surface = Glass.makeMenuPanel(content: list)
        surface.samplesBehindWindow = true
        panel.adoptPopupStyle(card: surface)
        panel.setAccessibilityRole(.menu)
        host.onDismiss = { [weak self] in self?.finish(runs: nil) }
        // A click in a submenu, or in the menu a submenu opened from, is inside the menu.
        host.keepsOpen = { [weak self] event in
            guard let self else { return false }
            return self.isInChain(event.window) || self.isOnAnchor(event)
        }
        // A submenu giving the keys back, or taking them, never closes a layer: the root's rules
        // (a click elsewhere, the app going inactive, Escape) close the whole chain.
        host.keepsOpenOnKeyLoss = { [weak self] in self.map { $0.child != nil || $0.parentMenu != nil } ?? false }
        list.onPick = { [weak self] index in self?.pick(index) }
        list.onOpenSubmenu = { [weak self] index in self?.openSubmenu(index, fromKeyboard: true) }
        list.onHoverRow = { [weak self] index in self?.hovered(index) }
        list.onBack = { [weak self] in self?.closeLayer() }
        list.onKeyEquivalent = { [weak self] event in self?.runKeyEquivalent(event) ?? false }
    }

    /// Whether the menu is on screen.
    public var isShown: Bool { host.isShown }

    /// Opens the menu over `anchor` (a control in a window) in `anchor`'s theme: above it with its
    /// leading edges lined up (`preferred` .above, the sidebar's bottom-left), or below. Returns false
    /// when it cannot show (no window, no visible row).
    @discardableResult
    public func show(from anchor: NSView, preferred: PopupPlacement.Side = .below) -> Bool {
        guard let window = anchor.window else { return false }
        anchorView = anchor
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return show(at: rect, in: window, preferred: preferred, scope: anchor.themeScope.fullStrength)
    }

    /// Opens the menu at `anchor` (screen) over `window`, in `scope` (the window's when nil).
    @discardableResult
    public func show(at anchor: CGRect, in window: NSWindow, preferred: PopupPlacement.Side = .below,
                     scope: ThemeScope? = nil) -> Bool {
        present(at: anchor, in: window, preferred: preferred, sideBySide: false, makeKey: true,
             scope: scope ?? window.themeScope.fullStrength)
    }

    private func present(at anchor: CGRect, in window: NSWindow, preferred: PopupPlacement.Side, sideBySide: Bool,
                      makeKey: Bool, scope: ThemeScope) -> Bool {
        menu.update()
        let rows = GlassMenuRow.rows(of: menu)
        guard rows.contains(where: { $0.item != nil }) else { return false }
        self.scope = scope
        scope.adopt(panel)
        list.load(rows)
        let size = list.fittingMenuSize()
        guard host.show(size: size, anchor: anchor, in: window, preferred: preferred, makeKey: makeKey,
                        sideBySide: sideBySide) != nil else { return false }
        // The rows fill the card the host placed (a screen too short for them shortens it).
        surface.layoutSubtreeIfNeeded()
        list.frame = surface.contentView.bounds
        list.needsLayout = true
        holdsSelf = self
        panel.makeFirstResponder(list)
        return true
    }

    /// Closes the menu and its submenus without running a row.
    public func close() { root.finish(runs: nil) }

    // MARK: Rows

    private func hovered(_ index: Int) {
        list.highlight(index)
        guard let row = list.row(at: index), let item = row.item, item.isEnabled, item.submenu != nil else {
            closeChild()
            takeKeys()
            return
        }
        openSubmenu(index, fromKeyboard: false)
    }

    /// The pointer in this menu: its keys follow the pointer, as a menu's do.
    private func takeKeys() {
        guard !panel.isKeyWindow, NSApp.isActive else { return }
        panel.makeKey()
        panel.makeFirstResponder(list)
    }

    private func pick(_ index: Int) {
        guard let row = list.row(at: index), let item = row.item, item.isEnabled else { return }
        if item.submenu != nil { return openSubmenu(index, fromKeyboard: true) }
        root.finish(runs: item)
    }

    /// Runs the root menu's item whose key equivalent `event` presses; false when none does.
    func runKeyEquivalent(_ event: NSEvent) -> Bool {
        let root = root
        guard let item = GlassMenuRow.item(matching: event, in: root.menu) else { return false }
        root.finish(runs: item)
        return true
    }

    private func openSubmenu(_ index: Int, fromKeyboard: Bool) {
        guard let row = list.row(at: index), let item = row.item, item.isEnabled, let submenu = item.submenu,
              let view = list.view(at: index), let window = panel.parent, let scope else { return }
        if let child, child.menu === submenu {
            if fromKeyboard { child.takeKeys(); child.list.highlightFirst() }
            return
        }
        closeChild()
        let next = GlassMenu(menu: submenu)
        next.parentMenu = self
        child = next
        let rect = panel.convertToScreen(view.convert(view.bounds, to: nil))
        guard next.present(at: rect, in: window, preferred: .below, sideBySide: true, makeKey: fromKeyboard, scope: scope) else {
            child = nil
            return
        }
        if fromKeyboard { next.list.highlightFirst() } else { takeKeys() }
    }

    private func closeChild() {
        guard let child else { return }
        child.finish(runs: nil, alone: true)
        self.child = nil
    }

    /// Left: a submenu closes alone and gives the keys back to the menu it opened from.
    private func closeLayer() {
        guard let parentMenu else { return }
        parentMenu.closeChild()
        parentMenu.takeKeys()
    }

    private var root: GlassMenu { parentMenu?.root ?? self }

    private func isOnAnchor(_ event: NSEvent) -> Bool {
        guard let anchor = root.anchorView, let window = anchor.window, event.window === window else { return false }
        return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
    }

    /// `window` is one of this chain's panels.
    private func isInChain(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        var menu: GlassMenu? = root
        while let current = menu {
            if current.panel === window { return true }
            menu = current.child
        }
        return false
    }

    /// Closes this menu and its submenus. Any dismiss of a submenu closes the whole chain unless
    /// `alone`. The root runs `item` on the next turn of the run loop, after its panels have gone.
    private func finish(runs item: NSMenuItem?, alone: Bool = false) {
        if !alone, let parentMenu { return parentMenu.root.finish(runs: item) }
        guard !closed else { return }
        closed = true
        closeChild()
        host.hide()
        holdsSelf = nil
        guard parentMenu == nil else { return }
        let done = onClose
        onClose = nil
        // The item's menu is held strongly here: `NSMenuItem.menu` is weak, and once `holdsSelf`
        // lets go nothing else may keep the NSMenu (the sidebar holds its GlassMenu weakly), so
        // reading `item.menu` on the next turn found nil and the row's action never ran (review
        // P1-F1 of #41538). The root menu is held too, which keeps a submenu's chain alive.
        let owner = item?.menu
        let rootMenu = menu
        // A run-loop callout, as the profile menu's open is: the row's action runs outside any
        // event the menu handled.
        MainRunLoopBlock.perform {
            done?()
            withExtendedLifetime(rootMenu) {
                guard let item, let owner else { return }
                let index = owner.index(of: item)
                if index >= 0 { owner.performActionForItem(at: index) }
            }
        }
    }
}

/// One line of a ``GlassMenu``: an item, or a separator (`item` nil).
struct GlassMenuRow {
    let item: NSMenuItem?

    /// The visible rows of `menu`: no hidden items, no item with a view of its own (the native header
    /// rows stay in `NSMenu`s), no separator first, last or twice.
    static func rows(of menu: NSMenu) -> [GlassMenuRow] {
        var rows: [GlassMenuRow] = []
        for item in menu.items where !item.isHidden && item.view == nil {
            if item.isSeparatorItem {
                if let last = rows.last, last.item != nil { rows.append(GlassMenuRow(item: nil)) }
            } else {
                rows.append(GlassMenuRow(item: item))
            }
        }
        if let last = rows.last, last.item == nil { rows.removeLast() }
        return rows
    }

    /// The enabled, visible item of `menu` (or of one of its submenus) whose key equivalent `event`
    /// presses, as `NSMenu.performKeyEquivalent(with:)` finds it: the same key, ignoring case, and
    /// the same Command, Option, Control and Shift (an uppercase key equivalent implies Shift).
    static func item(matching event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        guard event.type == .keyDown, let pressed = event.charactersIgnoringModifiers?.lowercased(), !pressed.isEmpty
        else { return nil }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = event.modifierFlags.intersection(relevant)
        for item in menu.items where !item.isHidden && !item.isSeparatorItem {
            if let submenu = item.submenu {
                submenu.update()
                if let found = Self.item(matching: event, in: submenu) { return found }
                continue
            }
            let key = item.keyEquivalent
            guard !key.isEmpty, item.isEnabled, key.lowercased() == pressed else { continue }
            var wanted = item.keyEquivalentModifierMask.intersection(relevant)
            if key != key.lowercased() { wanted.insert(.shift) }
            if wanted == flags { return item }
        }
        return nil
    }

    /// `item`'s shortcut as the menu draws it (⌘, for Settings), or nil without one.
    static func shortcut(_ item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        let shifted = key != key.lowercased()
        if mask.contains(.shift) || shifted { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        let names: [String: String] = ["\r": "↩", "\u{1b}": "⎋", "\t": "⇥", " ": "Space", "\u{8}": "⌫", "\u{7f}": "⌫"]
        return text + (names[key] ?? key.uppercased())
    }
}

/// The rows of a ``GlassMenu`` on the menu grid: ``MenuMetrics/highlightInset`` around them, the
/// icon at ``MenuMetrics/iconX``, the text on ``MenuMetrics/textX(iconColumn:stateColumn:)``, the
/// shortcut or chevron ``MenuMetrics/trailing`` from the edge, rows ``GlassMenuMaterial/rowHeight``
/// high, separators a hairline ``MenuMetrics/separatorInset`` in from the edges.
@MainActor
final class GlassMenuListView: NSView {
    var onPick: (Int) -> Void = { _ in }
    var onOpenSubmenu: (Int) -> Void = { _ in }
    var onHoverRow: (Int) -> Void = { _ in }
    var onBack: () -> Void = {}
    /// A key equivalent of one of the menu's items was pressed while the menu had the keys.
    var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }

    private var rows: [GlassMenuRow] = []
    private var views: [NSView] = []
    private var highlighted: Int?
    /// The rows' least and most width (points): a menu is as wide as its longest row within them.
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 360
    static let separatorHeight: CGFloat = 9

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func load(_ rows: [GlassMenuRow]) {
        self.rows = rows
        highlighted = nil
        views.forEach { $0.removeFromSuperview() }
        let iconColumn = rows.contains { $0.item?.image != nil }
        views = rows.enumerated().map { index, row in
            guard let item = row.item else { return GlassMenuSeparatorView() }
            let view = makeRow(item, iconColumn: iconColumn)
            view.onActivate = { [weak self] in self?.onPick(index) }
            view.onHover = { [weak self] in self?.onHoverRow(index) }
            return view
        }
        views.forEach(addSubview)
        setAccessibilityRole(.menu)
    }

    private func makeRow(_ item: NSMenuItem, iconColumn: Bool) -> PopupRowView {
        var layout = PopupRowView.Layout()
        let inset = MenuMetrics.highlightInset
        layout.leading = MenuMetrics.iconX - inset
        layout.leadingColumn = iconColumn ? MenuMetrics.iconSize : 0
        layout.gap = iconColumn ? MenuMetrics.iconGap : 0
        layout.trailing = MenuMetrics.trailing - inset
        layout.trailingGap = MenuMetrics.shortcutGap
        layout.minHeight = GlassMenuMaterial.rowHeight
        layout.hoverFills = false
        var subtitle: String?
        if #available(macOS 14.4, *) { subtitle = item.subtitle }
        let row = PopupRowView(leading: iconColumn ? icon(item.image) : nil, title: item.title, subtitle: subtitle,
                               trailing: trailing(item), layout: layout)
        row.isEnabled = item.isEnabled
        if let identifier = item.identifier { row.setAccessibilityIdentifier(identifier.rawValue) }
        row.setAccessibilityRole(.menuItem)
        return row
    }

    private func icon(_ image: NSImage?) -> NSView {
        let view = ThemedImageView()
        view.image = image?.fittedToMenuIconBox()
        view.imageScaling = .scaleProportionallyDown
        if image?.isTemplate ?? true { view.ink = .primary }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: MenuMetrics.iconSize),
            view.heightAnchor.constraint(equalToConstant: MenuMetrics.iconSize),
        ])
        return view
    }

    private func trailing(_ item: NSMenuItem) -> NSView? {
        if item.submenu != nil { return symbol("chevron.right", ink: .tertiary) }
        if item.state == .on { return symbol("checkmark", ink: .primary) }
        if item.state == .mixed { return symbol("minus", ink: .primary) }
        return GlassMenuRow.shortcut(item).map(PopupRowView.shortcut)
    }

    private func symbol(_ name: String, ink: ThemeInk) -> NSView {
        let view = ThemedImageView()
        view.image = NSImage.menuSymbol(name)
        view.ink = ink
        return view
    }

    /// The size the rows ask for: the widest row within ``minWidth`` and ``maxWidth``, every row's
    /// height and the inset above and below.
    func fittingMenuSize() -> CGSize {
        let inset = MenuMetrics.highlightInset
        var width = Self.minWidth
        var height = inset * 2
        for view in views {
            let size = view.fittingSize
            width = max(width, size.width + inset * 2)
            height += view is GlassMenuSeparatorView ? Self.separatorHeight : max(size.height, GlassMenuMaterial.rowHeight)
        }
        return CGSize(width: min(width, Self.maxWidth).rounded(.up), height: height.rounded(.up))
    }

    override func layout() {
        super.layout()
        let inset = MenuMetrics.highlightInset
        var y = inset
        for view in views {
            let height = view is GlassMenuSeparatorView ? Self.separatorHeight
                : max(view.fittingSize.height, GlassMenuMaterial.rowHeight)
            view.frame = CGRect(x: inset, y: y, width: bounds.width - inset * 2, height: height)
            y += height
        }
    }

    func row(at index: Int) -> GlassMenuRow? { rows.indices.contains(index) ? rows[index] : nil }
    func view(at index: Int) -> NSView? { views.indices.contains(index) ? views[index] : nil }

    func highlight(_ index: Int?) {
        highlighted = index
        for (offset, view) in views.enumerated() { (view as? PopupRowView)?.isHighlighted = offset == index }
    }

    func highlightFirst() { highlight(step(from: nil, by: 1)) }

    /// The next enabled row from `index` in `direction`, wrapping.
    private func step(from index: Int?, by direction: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        var next = index ?? (direction > 0 ? -1 : rows.count)
        for _ in rows.indices {
            next = (next + direction + rows.count) % rows.count
            if let item = rows[next].item, item.isEnabled { return next }
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: highlight(step(from: highlighted, by: 1))  // Down
        case 126: highlight(step(from: highlighted, by: -1))  // Up
        case 124: if let highlighted { onOpenSubmenu(highlighted) }  // Right
        case 123: onBack()  // Left (Escape is the popup host's: it closes the whole menu)
        case 36, 76, 49: if let highlighted { onPick(highlighted) }  // Return, Enter, Space
        default: if !onKeyEquivalent(event) { super.keyDown(with: event) }
        }
    }

    /// A shortcut pressed while the menu is open runs its row, as it does in an open `NSMenu`
    /// (⌘, opens Settings), instead of going nowhere.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

}

/// A menu's separator: one hairline, ``MenuMetrics/separatorInset`` in from the menu's edges.
@MainActor
final class GlassMenuSeparatorView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inset = MenuMetrics.separatorInset - MenuMetrics.highlightInset
        let line = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
        guard line > 0 else { return }
        performWithTheme {
            Palette.separator.setFill()
            NSRect(x: inset, y: (bounds.midY - line / 2), width: max(0, bounds.width - inset * 2), height: line).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
