public import AppKit
import CmuxNextCompat
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
/// 2026-10-12): the pinned actions' buttons, then "…". They hide at rest (`tabs.restingControlOpacity`,
/// 0 by default; Lawrence 2026-10-20) and fade in while the pointer is over the tab bar or these
/// controls (`HoverReveal`, like the strip's plus), while "…"'s menu is open and while one has keyboard
/// focus, and stay shown, "…" lit, while the pane is zoomed. Their width is kept while they are faded,
/// so no tab moves when they appear. The overflow glyph also stays in its trailing slot throughout
/// the opacity fade (Leo 2026-10-26). "…"'s menu opens on press (press-drag-release) and lists what
/// opens in the pane, then the actions without a button, Search Tabs, then Show in Tab Bar.
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
    /// The app's one more button (⋮, OverflowButton); its menu opens on press.
    public let moreButton = OverflowButton(label: Strings.paneMore)
    /// The tab bar's tracking area (``refreshCorner()``) reports the pointer.
    public private(set) lazy var reveal = HoverReveal(region: self, tracksPointer: false)
    private var corner: NSTrackingArea?
    private var restObservation: Task<Void, Never>?
    private weak var cornerHost: NSView?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        moreButton.setAccessibilityIdentifier("cmux.pane.more")
        moreButton.pressMenu = { [weak self] in self?.moreMenu?() }
        // "⋮" stays shown while its menu is up: the pointer leaves the corner for the menu.
        let present = moreButton.presentMenu
        moreButton.presentMenu = { [weak self] menu, button in
            let hold = self?.reveal.hold()
            present(menu, button)
            hold?.release()
        }
        moreButton.isHidden = true
        addSubview(moreButton)
        // Hidden at rest by default (Lawrence 2026-10-20; Leo's muted look is a value above 0); a Debug
        // Settings change applies at once. task-owner: this view (cancelled in deinit); event-driven.
        reveal.restAlpha = TabTunables.restingControlOpacity.value
        _ = reveal.add(moreButton)
        restObservation = Task { [weak self] in
            for await rest in ObservationStream({ TabTunables.restingControlOpacity.value }) { self?.reveal.restAlpha = rest }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { restObservation?.cancel() }
    }

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
            button.setAccessibilityIdentifier("cmux.pane.toolbar.\(item.id)")
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
        let inset = Self.edgeInset(height: PaneChromeMetrics.current.resolvedStripHeight(scale: 2))
        return NSSize(width: CGFloat(count) * side + CGFloat(count - 1) * Metrics.space1 / 2 + inset, height: NSView.noIntrinsicMetric)
    }

    private var shownCount: Int { buttons.count + (hasMore ? 1 : 0) }

    override public func layout() {
        super.layout()
        let side = TitlebarBandButton.side, gap = Metrics.space1 / 2
        // Fixed slots from the trailing end: "…" in the last (kept while it hides), the buttons before it
        // in order, so Search Tabs keeps its place whichever tab is selected and fewer pins leave room
        // only at the leading end.
        let y = Self.edgeInset(height: bounds.height)
        func slotX(_ fromTrailing: Int) -> CGFloat { bounds.width - y - side - CGFloat(fromTrailing) * (side + gap) }
        moreButton.frame = moreFrame()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: max(0, slotX(buttons.count - index)), y: y, width: side, height: side)
        }
        applyTint()
    }

    /// The trailing slot is independent of hover, focus and menu holds. HoverReveal owns only
    /// opacity, so the glyph and its hit target stay aligned throughout the fade.
    func moreFrame() -> NSRect {
        let side = TitlebarBandButton.side
        let inset = Self.edgeInset(height: bounds.height)
        return NSRect(x: max(0, bounds.width - inset - side), y: inset, width: side, height: side)
    }

    /// The buttons' gap above them in a bar `height` tall, which is also the "…" button's gap to
    /// the trailing edge, so it rests evenly in the pane's corner as the first tab does.
    static func edgeInset(height: CGFloat) -> CGFloat {
        max(0, ((height - TitlebarBandButton.side) / 2).rounded())
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    /// Lit: the lit glyph (the accent, never fainter than at rest); else the chrome's secondary text.
    /// Runs again on a theme change.
    private func applyTint() {
        moreButton.tintOverride = lit ? performWithTheme { Palette.litGlyph } : nil
        for (button, item) in zip(buttons, items) { button.contentTintColor = performWithTheme { item.lit ? Palette.litGlyph : Palette.textSecondary } }
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
        // Any control that shows (Search Tabs with a chat selected has no "…") brightens on hover.
        let live = superview != nil && window != nil && (hasMore || !buttons.isEmpty) && !isHiddenOrHasHiddenAncestor
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
}

// Like the strip's empty space (TabStripView+TitlebarDrag): in the window's top row, a press
// around the buttons moves the window; a button never does.
extension PaneToolbarView: TitlebarPressDeciding {
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        let point = convert(windowPoint, from: nil)
        let onButton = (buttons as [NSView] + [moreButton]).contains { !$0.isHidden && $0.frame.contains(point) }
        return !onButton && WindowTitlebar.isInTopRow(self) ? .movesWindow : .staysPut
    }
}
