import AppKit
import CmuxNextDesign

/// The pane's one control at the tab bar's trailing end (``PaneToolbar``; Leo 2026-10-12): "…",
/// which fades in while the pointer is over the pane's top-right corner (`HoverReveal`, like the
/// strip's plus) and while its menu is open, and stays shown and lit while the pane is zoomed.
/// Its menu opens on press (press-drag-release) and lists what opens in the pane, then the shown
/// tab's own actions.
final class PaneToolbarView: NSView {
    /// "…"'s menu; nil or empty offers nothing.
    var moreMenu: (() -> NSMenu?)?

    private(set) var hasMore = false
    private(set) var lit = false
    let moreButton = TitlebarBandButton(symbol: "ellipsis")
    private(set) lazy var reveal = HoverReveal(region: self)

    override init(frame: NSRect) {
        super.init(frame: frame)
        moreButton.target = self
        moreButton.action = #selector(openMore)
        moreButton.longPressOpensMenu = false
        moreButton.setAccessibilityLabel(PaneToolbarStrings.more)
        moreButton.themedToolTip = PaneToolbarStrings.more
        moreButton.pressMenu = { [weak self] in self?.moreMenu?() }
        // "…" stays shown while its menu is up: the pointer leaves the corner for the menu.
        let present = moreButton.presentMenu
        moreButton.presentMenu = { [weak self] menu, button in
            let hold = self?.reveal.hold()
            present(menu, button)
            hold?.release()
        }
        moreButton.isHidden = true
        addSubview(moreButton)
        _ = reveal.add(moreButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Whether "…" has a menu, and whether it is lit (the pane is zoomed: shown without hover).
    func show(more: Bool, lit: Bool) {
        guard more != hasMore || lit != self.lit else { return }
        hasMore = more
        self.lit = lit
        moreButton.isHidden = !more
        moreButton.state = lit ? .on : .off
        moreButton.contentTintColor = performWithTheme { lit ? Palette.accent : Palette.textSecondary }
        reveal.isEnabled = !lit
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true // the strip gives up this width (PaneContentView+Toolbar)
    }

    /// Nothing to offer: no width, so the strip keeps the whole bar.
    override var intrinsicContentSize: NSSize {
        guard hasMore else { return NSSize(width: 0, height: NSView.noIntrinsicMetric) }
        return NSSize(width: TitlebarBandButton.side + Metrics.space2, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        let side = TitlebarBandButton.side
        moreButton.frame = NSRect(x: 0, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
    }

    /// A keyboard or VoiceOver press; a pointer press opens the menu on mouse-down.
    @objc private func openMore() {
        guard let menu = moreMenu?(), !menu.items.isEmpty else { return }
        moreButton.presentMenu(menu, moreButton)
    }
}

// Like the strip's empty space (TabStripView+TitlebarDrag): in the window's top row, a press
// around "…" moves the window; "…" never does.
extension PaneToolbarView: TitlebarPressDeciding {
    func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        let point = convert(windowPoint, from: nil)
        let onButton = !moreButton.isHidden && moreButton.frame.contains(point)
        return !onButton && WindowTitlebar.isInTopRow(self) ? .movesWindow : .staysPut
    }
}
