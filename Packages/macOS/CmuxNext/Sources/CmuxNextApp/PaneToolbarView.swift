import AppKit
import CmuxNextActions
import CmuxNextDesign

/// One button of a pane's toolbar: an action's symbol, its title and key in the tooltip.
struct PaneToolbarItem: Equatable {
    let id: ActionID
    let title: String
    let symbol: String
    let shortcut: String?
    /// On: the zoom button of a zoomed pane.
    var lit = false
}

/// The pane's buttons at the tab bar's trailing end (``PaneToolbar``, cx-kk7lm): a few action
/// symbols and "…" for the rest. A button's right-click offers Hide <title> Button, the row's and
/// "…"'s right-click Show for each hidden one (the HideableChrome rule, webviews/src/ui).
final class PaneToolbarView: NSView {
    /// Runs a button's action, or a "…" menu's.
    var onPerform: ((ActionID) -> Void)?
    /// Hide (false) or Show (true) for a button.
    var onSetShown: ((ActionID, Bool) -> Void)?
    /// "…": the menu of the actions without a button.
    var moreMenu: (() -> NSMenu?)?

    private(set) var shown: [PaneToolbarItem] = []
    private(set) var hiddenItems: [PaneToolbarItem] = []
    private(set) var hasMore = false
    private(set) var buttons: [TitlebarBandButton] = []
    let moreButton = TitlebarBandButton(symbol: "ellipsis")

    override init(frame: NSRect) {
        super.init(frame: frame)
        moreButton.target = self
        moreButton.action = #selector(openMore)
        moreButton.longPressOpensMenu = false
        moreButton.setAccessibilityLabel(PaneToolbarStrings.more)
        moreButton.themedToolTip = PaneToolbarStrings.more
        moreButton.menuProvider = { [weak self] in self?.showMenu() }
        moreButton.pressMenu = { [weak self] in self?.moreMenu?() }
        addSubview(moreButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The buttons to show, whether "…" shows, and the hidden ones Show brings back.
    func show(_ shown: [PaneToolbarItem], more: Bool, hidden: [PaneToolbarItem]) {
        hiddenItems = hidden
        guard shown != self.shown || more != hasMore else { return }
        self.shown = shown
        hasMore = more
        buttons.forEach { $0.removeFromSuperview() }
        buttons = shown.enumerated().map { index, item in
            let button = TitlebarBandButton(symbol: item.symbol)
            button.tag = index
            button.target = self
            button.action = #selector(press(_:))
            button.longPressOpensMenu = false
            button.setAccessibilityLabel(item.title)
            button.themedToolTip = item.title
            button.themedToolTipShortcut = item.shortcut
            // The lit zoom button says the pane is zoomed: nothing to hide.
            button.menuProvider = item.lit ? nil : { [weak self] in self?.hideMenu(item) }
            button.state = item.lit ? .on : .off
            if item.lit { button.contentTintColor = performWithTheme { Palette.accent } }
            addSubview(button)
            return button
        }
        moreButton.isHidden = !more
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true // the strip gives up this width (PaneContentView+Toolbar)
    }

    /// Nothing shown: no width, so the strip keeps the whole bar.
    override var intrinsicContentSize: NSSize {
        let count = buttons.count + (hasMore ? 1 : 0)
        guard count > 0 else { return NSSize(width: 0, height: NSView.noIntrinsicMetric) }
        let side = TitlebarBandButton.side
        return NSSize(width: CGFloat(count) * side + CGFloat(count - 1) * Metrics.space1 / 2 + Metrics.space2, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        let side = TitlebarBandButton.side
        var x: CGFloat = 0
        for button in buttons + (hasMore ? [moreButton] : []) {
            button.frame = NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
            x += side + Metrics.space1 / 2
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = showMenu() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func press(_ sender: TitlebarBandButton) {
        guard shown.indices.contains(sender.tag) else { return }
        onPerform?(shown[sender.tag].id)
    }

    @objc private func openMore() {
        guard let menu = moreMenu?(), !menu.items.isEmpty else { return }
        moreButton.presentMenu(menu, moreButton)
    }

    /// A button's right-click: Hide <title> Button.
    func hideMenu(_ item: PaneToolbarItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(PaneToolbarStrings.hide(item.title), item, shown: false))
        return menu
    }

    /// The row's right-click: Show <title> Button for each hidden one; none with nothing hidden.
    func showMenu() -> NSMenu? {
        guard !hiddenItems.isEmpty else { return nil }
        let menu = NSMenu()
        hiddenItems.forEach { menu.addItem(menuItem(PaneToolbarStrings.show($0.title), $0, shown: true)) }
        return menu
    }

    private func menuItem(_ title: String, _ item: PaneToolbarItem, shown: Bool) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: #selector(setShown(_:)), keyEquivalent: "")
        row.target = self
        row.representedObject = PaneToolbarToggle(id: item.id, shown: shown)
        row.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        return row
    }

    @objc private func setShown(_ sender: NSMenuItem) {
        guard let toggle = sender.representedObject as? PaneToolbarToggle else { return }
        onSetShown?(toggle.id, toggle.shown)
    }
}

/// A Hide or Show row's payload.
private final class PaneToolbarToggle: NSObject {
    let id: ActionID
    let shown: Bool
    init(id: ActionID, shown: Bool) {
        self.id = id
        self.shown = shown
    }
}

// Like the strip's empty space (TabStripView+TitlebarDrag): in the window's top row, a press
// between or around the buttons moves the window; a button never does.
extension PaneToolbarView: TitlebarPressDeciding {
    func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        let point = convert(windowPoint, from: nil)
        let onButton = (buttons + [moreButton]).contains { !$0.isHidden && $0.frame.contains(point) }
        return !onButton && WindowTitlebar.isInTopRow(self) ? .movesWindow : .staysPut
    }
}
