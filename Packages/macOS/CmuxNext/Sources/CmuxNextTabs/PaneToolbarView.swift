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
    public var alwaysVisible = false

    public init(id: String, title: String, symbol: String, shortcut: String?, lit: Bool = false, alwaysVisible: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.lit = lit
        self.alwaysVisible = alwaysVisible
    }
}

/// The pane's controls at the tab bar's trailing end (``PaneToolbar``; Leo 2026-10-12, Lawrence
/// 2026-10-12): the pinned actions' buttons, then "…". They hide at rest (`tabs.restingControlOpacity`,
/// 0 by default; Lawrence 2026-10-20) while the tabs leave room, show muted at rest once the tabs fill
/// the bar (`tabs.crowdedControls`; Leo 2026-10-20), and fade in while the pointer is over the tab bar or these
/// controls (`HoverReveal`, like the strip's plus), while "…"'s menu is open and while one has keyboard
/// focus, and stay shown, "…" and a pinned zoom button lit, while the pane is zoomed (the selected
/// tab carries the zoom indicator, `TabStripModel.zoomsSelected`). Their width is kept while they are faded,
/// so no tab moves when they appear. The overflow glyph also stays in its trailing slot throughout
/// the opacity fade (Leo 2026-10-26). "…"'s menu opens on press (press-drag-release) and lists what
/// opens in the pane, then the actions without a button, Search Tabs, then Show in Tab Bar.
public final class PaneToolbarView: NSView {
    /// "…"'s menu; nil or empty offers nothing.
    public var moreMenu: (() -> NSMenu?)?
    /// Runs a pinned button's action (its catalog id).
    public var onPerform: ((String) -> Void)?
    public var onNativeTool: ((String, String?) -> Void)?
    /// Owner-checked URL selection, paired with the tab-row event publication.
    public var onNativeToolURL: ((String, String?, URL) -> Void)?
    /// Opens a validated native menu URL. Injectable for tests; production uses AppKit's workspace.
    public var openURL: (URL) -> Void = { NSWorkspace.shared.openInBackground($0) }
    /// The pane's tab bar, a sibling: hovering its frame reveals the controls too, and once its tabs
    /// fill it (``TabStripView/isCrowded``) the controls show at rest (`tabs.crowdedControls`).
    public weak var strip: TabStripView? {
        didSet {
            strip?.onCrowdedChange = { [weak self] _ in self?.applyRest() }
            applyRest()
        }
    }

    public private(set) var hasMore = false
    public private(set) var lit = false
    public private(set) var items: [PaneToolbarItem] = []
    /// Buttons' room the bar keeps even while fewer show (``show(_:more:lit:reserving:)``).
    public private(set) var reservedCount = 0
    public private(set) var buttons: [TitlebarBandButton] = []
    public private(set) var nativeItems: [PaneTabRowTool] = []
    public private(set) var nativeButtons: [TitlebarBandButton] = []
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
        applyRest()
        _ = reveal.add(moreButton)
        restObservation = Task { [weak self] in
            for await _ in ObservationStream({
                (TabTunables.restingControlOpacity.value, TabTunables.crowdedControls.value, TabTunables.crowdedControlOpacity.value)
            }) { self?.applyRest() }
        }
    }

    /// Hidden at rest while the tabs leave room; muted once they fill the bar (Leo 2026-10-20: no
    /// reservation of hidden icons, and no push or overlay that takes the rightmost tabs away).
    private func applyRest() {
        reveal.restAlpha = TabTunables.restingControlAlpha(crowded: strip?.isCrowded ?? false)
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
    public func show(_ items: [PaneToolbarItem] = [], more: Bool, lit: Bool, reserving: Int = 0,
                     nativeItems: [PaneTabRowTool] = []) {
        guard items != self.items || more != hasMore || lit != self.lit || reserving != reservedCount || nativeItems != self.nativeItems else { return }
        reservedCount = reserving
        if items != self.items { setButtons(items) }
        if nativeItems != self.nativeItems { setNativeButtons(nativeItems) }
        self.nativeItems = nativeItems
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
            if !item.alwaysVisible { reveal.add(button) }
            return button
        }
    }

    private func setNativeButtons(_ items: [PaneTabRowTool]) {
        nativeButtons.forEach { reveal.remove($0); $0.removeFromSuperview() }
        nativeButtons = items.enumerated().map { index, item in
            let button = TitlebarBandButton(symbol: item.symbol, text: item.text)
            button.tag = index
            button.setAccessibilityLabel(item.label)
            button.setAccessibilityIdentifier("cmux.pane.native-toolbar.\(item.id)")
            button.themedToolTip = item.label
            button.state = item.toggled ? .on : .off
            button.isEnabled = item.enabled
            button.badge = item.badge
            if item.menu.isEmpty {
                button.target = self
                button.action = #selector(pressNative(_:))
            } else {
                button.target = self
                button.action = #selector(pressNative(_:))
                button.pressMenu = { [weak self] in self?.menu(for: item) }
                let present = button.presentMenu
                button.presentMenu = { [weak self] menu, source in
                    let hold = self?.reveal.hold()
                    present(menu, source)
                    hold?.release()
                }
            }
            addSubview(button)
            reveal.add(button)
            return button
        }
    }

    private func menu(for tool: PaneTabRowTool) -> NSMenu? {
        let menu = NSMenu(title: tool.label)
        let invoke = onNativeTool
        let invokeURL = onNativeToolURL
        menu.autoenablesItems = false
        for item in tool.menu { menu.addItem(menuItem(item, tool: tool, ancestorsEnabled: tool.enabled, invoke: invoke, invokeURL: invokeURL)) }
        return menu
    }

    /// Native tools remain reachable from the overflow menu when a narrow pane cannot fit every
    /// supplied button: only those whose button is hidden, so a tool that shows is not listed twice.
    /// The same invoker path keeps the page event identical to a direct press.
    public func nativeOverflowItems() -> [NSMenuItem] {
        let invoke = onNativeTool
        let invokeURL = onNativeToolURL
        layoutSubtreeIfNeeded()
        return zip(nativeItems, nativeButtons).compactMap { tool, button in button.isHidden ? tool : nil }.map { tool in
            let row = NSMenuItem(title: tool.text ?? tool.label, action: nil, keyEquivalent: "")
            row.isEnabled = tool.enabled
            row.state = tool.toggled ? .on : .off
            let invoker = NativeMenuInvoker(enabled: { [weak self] in
                tool.enabled && self?.nativeItems.contains(tool) == true
            }) {
                guard tool.menu.isEmpty else { return }
                invoke?(tool.id, nil)
            }
            row.action = #selector(NativeMenuInvoker.run)
            row.target = invoker
            row.representedObject = invoker
            if !tool.menu.isEmpty {
                let submenu = NSMenu(title: tool.label)
                submenu.autoenablesItems = false
                tool.menu.forEach { submenu.addItem(menuItem($0, tool: tool, ancestorsEnabled: tool.enabled, invoke: invoke, invokeURL: invokeURL)) }
                row.submenu = submenu
            }
            return row
        }
    }

    private func menuItem(_ item: PaneTabRowMenuItem, tool: PaneTabRowTool, ancestorsEnabled: Bool,
                          invoke: ((String, String?) -> Void)?, invokeURL: ((String, String?, URL) -> Void)?) -> NSMenuItem {
        let row = NSMenuItem(title: item.label, action: #selector(NativeMenuInvoker.run), keyEquivalent: "")
        let enabled = ancestorsEnabled && item.enabled
        row.isEnabled = enabled
        if let checked = item.checked { row.state = checked ? .on : .off }
        let invoker = NativeMenuInvoker(enabled: { [weak self] in
            enabled && self?.nativeItems.contains(tool) == true
        }) {
            guard item.children.isEmpty else { return }
            if let rawURL = item.url, let url = URL(string: rawURL) {
                invokeURL?(tool.id, item.id, url)
            } else {
                invoke?(tool.id, item.id)
            }
        }
        row.target = invoker
        row.representedObject = invoker
        if !item.children.isEmpty {
            let submenu = NSMenu(title: item.label)
            submenu.autoenablesItems = false
            item.children.forEach { submenu.addItem(self.menuItem($0, tool: tool, ancestorsEnabled: enabled, invoke: invoke, invokeURL: invokeURL)) }
            row.submenu = submenu
        }
        return row
    }

    /// Nothing to offer: no width, so the strip keeps the whole bar.
    override public var intrinsicContentSize: NSSize {
        let allButtons = buttons + nativeButtons
        let count = max(shownCount, reservedCount)
        guard count > 0 else { return NSSize(width: 0, height: NSView.noIntrinsicMetric) }
        let inset = Self.edgeInset(height: PaneChromeMetrics.current.resolvedStripHeight(scale: 2))
        let buttonWidth = allButtons.reduce(CGFloat.zero) { $0 + $1.preferredWidth }
        let reservedWidth = CGFloat(max(0, count - allButtons.count)) * TitlebarBandButton.side
        let gaps = CGFloat(max(count - 1, 0)) * Metrics.space1 / 2
        return NSSize(width: buttonWidth + reservedWidth + gaps + inset,
                      height: NSView.noIntrinsicMetric)
    }

    private var shownCount: Int { buttons.count + nativeButtons.count + (hasMore ? 1 : 0) }

    override public func layout() {
        super.layout()
        let side = TitlebarBandButton.side, gap = Metrics.space1 / 2
        // Fixed slots from the trailing end: "…" in the last (kept while it hides), the buttons before it
        // in order, so Search Tabs keeps its place whichever tab is selected and fewer pins leave room
        // only at the leading end.
        let y = Self.edgeInset(height: bounds.height)
        moreButton.frame = moreFrame()
        let allButtons = buttons + nativeButtons
        let trailingSlot = hasMore || reservedCount > allButtons.count ? 1 : 0
        let widths = allButtons.map(\.preferredWidth)
        // Creation actions remain in the + menu. Fold their buttons away together when the
        // pane caps this toolbar's width, keeping pins in their trailing slots. Pins that also
        // cannot fit return to the more menu instead of overlapping the remaining controls.
        let requiredWidth = y + widths.reduce(0, +) + CGFloat(max(0, allButtons.count - 1)) * gap
            + CGFloat(trailingSlot) * (side + gap)
        let creationFits = requiredWidth <= bounds.width
        var cursor = bounds.width - y - CGFloat(trailingSlot) * (side + gap)
        for index in allButtons.indices.reversed() {
            let button = allButtons[index]
            let available = max(0, cursor)
            // A button needs its complete icon slot to stay reachable. If only a
            // partial slot remains, hide it so nativeOverflowItems() can expose it
            // under the trailing menu instead of drawing over the neighbor.
            let fits = available >= side
            let width = fits ? min(widths[index], available) : 0
            let x = cursor - width
            button.isHidden = !fits || x < 0 || (index < items.count && items[index].alwaysVisible && !creationFits)
            button.frame = NSRect(x: max(0, x), y: y, width: max(side, width), height: side)
            cursor = x - gap
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
        for (button, item) in zip(nativeButtons, nativeItems) {
            button.contentTintColor = performWithTheme { item.toggled ? Palette.litGlyph : Palette.textSecondary }
        }
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
        let rect = strip.map { $0.frame.union(frame) } ?? frame
        // Any control that shows (Search Tabs with a chat selected has no "…") brightens on hover.
        let live = superview != nil && window != nil && (hasMore || !buttons.isEmpty || !nativeButtons.isEmpty) && !isHiddenOrHasHiddenAncestor
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

    @objc private func pressNative(_ sender: TitlebarBandButton) {
        guard sender.isEnabled, nativeItems.indices.contains(sender.tag) else { return }
        if !nativeItems[sender.tag].menu.isEmpty {
            sender.performPressMenu()
            return
        }
        onNativeTool?(nativeItems[sender.tag].id, nil)
    }
}

private final class NativeMenuInvoker: NSObject, NSMenuItemValidation {
    let enabled: () -> Bool
    let action: () -> Void
    init(enabled: @escaping () -> Bool, action: @escaping () -> Void) {
        self.enabled = enabled
        self.action = action
    }
    @objc func run() {
        guard enabled() else { return }
        action()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let value = enabled()
        menuItem.isEnabled = value
        return value
    }
}

// Like the strip's empty space (TabStripView+TitlebarDrag): in the window's top row, a press
// around the buttons moves the window; a button never does.
extension PaneToolbarView: TitlebarPressDeciding {
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        let point = convert(windowPoint, from: nil)
        let onButton = ((buttons + nativeButtons).map { $0 as NSView } + [moreButton]).contains { !$0.isHidden && $0.frame.contains(point) }
        return !onButton && WindowTitlebar.isInTopRow(self) ? .movesWindow : .staysPut
    }
}
