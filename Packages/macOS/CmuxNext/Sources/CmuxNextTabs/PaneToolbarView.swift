public import AppKit
public import CmuxNextDesign

/// A pinned action's button (`tabs.toolbarButtons`): its symbol, its title and key in the tooltip.
public struct PaneToolbarItem: Equatable, Sendable {
    /// The catalog action it runs.
    public let id: String
    public let title: String
    public let symbol: String
    public let shortcut: String?
    /// On: the zoom button of a zoomed pane.
    public var lit = false

    public init(id: String, title: String, symbol: String, shortcut: String?, lit: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.lit = lit
    }
}

/// The pane's controls at the tab bar's trailing end (``PaneToolbar``; Leo 2026-10-12, Lawrence
/// 2026-10-12): the pinned actions' buttons, then "…". They fade in place while the pointer is over
/// the tab bar or these controls (`HoverReveal`, like the strip's plus) and while "…"'s menu is open,
/// and stay shown, "…" lit, while the pane is zoomed. Their width is kept while they are faded, so
/// nothing moves when they appear. "…"'s menu opens on press (press-drag-release) and lists what
/// opens in the pane, then the actions without a button, then Show in Tab Bar.
public final class PaneToolbarView: NSView {
    /// "…"'s menu; nil or empty offers nothing.
    public var moreMenu: (() -> NSMenu?)?
    /// Runs a pinned button's action (its catalog id).
    public var onPerform: ((String) -> Void)?
    /// The tab bar's frame in the superview: hovering it reveals the controls too.
    public var stripFrame: (() -> NSRect?)?

    public private(set) var hasMore = false
    public private(set) var lit = false
    public private(set) var items: [PaneToolbarItem] = []
    /// Buttons' room the bar keeps even while fewer show (``show(_:more:lit:reserving:)``).
    public private(set) var reservedCount = 0
    public private(set) var buttons: [TitlebarBandButton] = []
    public let moreButton = TitlebarBandButton(symbol: "ellipsis")
    /// The tab bar's tracking area (``refreshCorner()``) reports the pointer.
    public private(set) lazy var reveal = HoverReveal(region: self, tracksPointer: false)
    private var corner: NSTrackingArea?
    private weak var cornerHost: NSView?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        moreButton.target = self
        moreButton.action = #selector(openMore)
        moreButton.longPressOpensMenu = false
        moreButton.setAccessibilityLabel(Strings.paneMore)
        moreButton.themedToolTip = Strings.paneMore
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
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var mouseDownCanMoveWindow: Bool { false }

    /// The pinned buttons, whether "…" has a menu, and whether it is lit (the pane is zoomed: shown without hover).
    ///
    /// - Parameter reserving: buttons' room to keep even while fewer show: the most any tab of the
    ///   pane shows, so the strip's width (and every tab's) does not follow the selected tab.
    public func show(_ items: [PaneToolbarItem] = [], more: Bool, lit: Bool, reserving: Int = 0) {
        guard items != self.items || more != hasMore || lit != self.lit || reserving != reservedCount else { return }
        reservedCount = reserving
        if items != self.items { setButtons(items) }
        hasMore = more
        self.lit = lit
        moreButton.isHidden = !more
        moreButton.state = lit ? .on : .off
        applyTint()
        reveal.isEnabled = !lit
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true // the strip gives up this width (PaneContentView+Toolbar)
        refreshCorner()
    }

    private func setButtons(_ items: [PaneToolbarItem]) {
        self.items = items
        buttons.forEach { reveal.remove($0); $0.removeFromSuperview() }
        buttons = items.enumerated().map { index, item in
            let button = TitlebarBandButton(symbol: item.symbol)
            button.tag = index
            button.target = self
            button.action = #selector(press(_:))
            button.longPressOpensMenu = false
            button.setAccessibilityLabel(item.title)
            button.themedToolTip = item.title
            button.themedToolTipShortcut = item.shortcut
            button.state = item.lit ? .on : .off
            addSubview(button)
            reveal.add(button)
            return button
        }
    }

    /// Nothing to offer: no width, so the strip keeps the whole bar.
    override public var intrinsicContentSize: NSSize {
        let count = max(shownCount, reservedCount)
        guard count > 0 else { return NSSize(width: 0, height: NSView.noIntrinsicMetric) }
        let side = TitlebarBandButton.side
        return NSSize(width: CGFloat(count) * side + CGFloat(count - 1) * Metrics.space1 / 2 + Metrics.space2, height: NSView.noIntrinsicMetric)
    }

    private var shownCount: Int { buttons.count + (hasMore ? 1 : 0) }

    override public func layout() {
        super.layout()
        let side = TitlebarBandButton.side
        // At the trailing end: "…" keeps its place while the reserved room on its leading side is empty.
        let used = shownCount > 0 ? CGFloat(shownCount) * side + CGFloat(shownCount - 1) * Metrics.space1 / 2 + Metrics.space2 : 0
        var x = max(0, bounds.width - used)
        for button in buttons + [moreButton] {
            button.frame = NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
            x += side + Metrics.space1 / 2
        }
        applyTint()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    /// Lit: the accent; else the chrome's secondary text. Runs again on a theme change.
    private func applyTint() {
        moreButton.contentTintColor = performWithTheme { lit ? Palette.accent : Palette.textSecondary }
        for (button, item) in zip(buttons, items) { button.contentTintColor = performWithTheme { item.lit ? Palette.accent : Palette.textSecondary } }
    }

    // MARK: The tab bar

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTint()
        refreshCorner()
    }

    override public func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        refreshCorner()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshCorner()
    }

    override public func viewDidHide() {
        super.viewDidHide()
        refreshCorner()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        refreshCorner()
    }

    /// Tracks the tab bar and this view in the superview, so hovering the tabs reveals the controls
    /// like the strip's plus (the pane calls it after each layout: the strip's frame may change
    /// alone). An unchanged rect keeps its area (an exit between removal and a new area is lost,
    /// `HoverRevealProbe`). Reads the pointer once, so a bar that moves under a still pointer is
    /// right before the next move.
    public func refreshCorner() {
        let rect = stripFrame?().map { $0.union(frame) } ?? frame
        let live = superview != nil && window != nil && hasMore && !isHiddenOrHasHiddenAncestor
        if live, let corner, corner.rect == rect, cornerHost === superview { return }
        if let corner { cornerHost?.removeTrackingArea(corner) }
        corner = nil
        guard let host = superview, let window, live else {
            reveal.setPointerInside(false)
            return
        }
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        host.addTrackingArea(area)
        corner = area
        cornerHost = host
        reveal.setPointerInside(rect.contains(host.convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    // The tab bar's is this view's only tracking area (the reveal's probe and "…"'s hover own theirs).
    override public func mouseEntered(with event: NSEvent) { reveal.setPointerInside(true) }
    override public func mouseExited(with event: NSEvent) { reveal.setPointerInside(false) }

    @objc private func press(_ sender: TitlebarBandButton) {
        guard items.indices.contains(sender.tag) else { return }
        onPerform?(items[sender.tag].id)
    }

    /// A keyboard or VoiceOver press; a pointer press opens the menu on mouse-down.
    @objc private func openMore() {
        guard let menu = moreMenu?(), !menu.items.isEmpty else { return }
        moreButton.presentMenu(menu, moreButton)
    }
}

// Like the strip's empty space (TabStripView+TitlebarDrag): in the window's top row, a press
// around the buttons moves the window; a button never does.
extension PaneToolbarView: TitlebarPressDeciding {
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        let point = convert(windowPoint, from: nil)
        let onButton = (buttons + [moreButton]).contains { !$0.isHidden && $0.frame.contains(point) }
        return !onButton && WindowTitlebar.isInTopRow(self) ? .movesWindow : .staysPut
    }
}
