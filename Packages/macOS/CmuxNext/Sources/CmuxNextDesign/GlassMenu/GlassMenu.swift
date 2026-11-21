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

    // MARK: Press tracking

    /// Follows the press that opened the menu, as an `NSMenu` tracks the press on its pop-up button
    /// (Lawrence, 2026-11-17: "now mousedown drag mouseup doesnt work like it does natively"). The
    /// control that took the press keeps the mouse, so its drags and its release reach the control,
    /// never the menu's panels: the control hands each one here.
    ///
    /// - A drag over a row highlights it (and opens its submenu); off every row, the deepest menu
    ///   shows no highlight.
    /// - A release on an enabled row without a submenu runs it. A release elsewhere in the menu
    ///   (a separator, a disabled row, a submenu's row) leaves it open.
    /// - A release on the control is a click: the menu stays open for a second click.
    /// - A release anywhere else closes the menu and runs nothing.
    ///
    /// - Parameter event: a `leftMouseDragged` or `leftMouseUp` of the press, in the control's window.
    public func trackPress(_ event: NSEvent) {
        let root = root
        guard !root.closed, root.isShown, let window = event.window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let hit = root.hit(at: point)
        switch event.type {
        case .leftMouseDragged:
            guard let (menu, index) = hit else {
                root.deepest.list.highlight(nil)
                return
            }
            if let index, let item = menu.list.row(at: index)?.item, item.isEnabled {
                menu.hovered(index)
            } else if menu.child == nil {
                menu.list.highlight(nil)
            }
        case .leftMouseUp:
            if let (menu, index) = hit {
                guard let index, let item = menu.list.row(at: index)?.item, item.isEnabled, item.submenu == nil else { return }
                root.finish(runs: item)
                return
            }
            if root.isOnAnchor(screenPoint: point) { return }
            root.finish(runs: nil)
        default:
            return
        }
    }

    /// The last open menu of the chain (the root without a submenu open).
    private var deepest: GlassMenu { child?.deepest ?? self }

    /// The menu of the chain under `point` (screen), innermost first, with the row under it (nil on
    /// the inset or a gap).
    private func hit(at point: CGPoint) -> (GlassMenu, Int?)? {
        var chain: [GlassMenu] = []
        var menu: GlassMenu? = self
        while let current = menu {
            chain.append(current)
            menu = current.child
        }
        for current in chain.reversed() where current.isShown && current.panel.frame.contains(point) {
            let local = current.list.convert(current.panel.convertPoint(fromScreen: point), from: nil)
            return (current, current.list.index(at: local))
        }
        return nil
    }

    private func isOnAnchor(screenPoint point: CGPoint) -> Bool {
        guard let anchor = anchorView, let window = anchor.window else { return false }
        return anchor.bounds.contains(anchor.convert(window.convertPoint(fromScreen: point), from: nil))
    }

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
