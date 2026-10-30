public import AppKit
public import CmuxNextWakeups

/// The deadline of a toolbar button's long press: a `visible` ``MainDeadline`` in the app (the menu shows
/// behind the person's input, not in FIFO order beside it), a fake in tests.
@MainActor
public protocol LongPressDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    /// Drops the pending deadline.
    func cancel()
}

extension MainDeadline: LongPressDeadline {}

/// An icon button of the toolbar band and the pane's tab bar controls: the chrome's hover and
/// pressed look.
public final class TitlebarBandButton: ClickableButton {
    public static var side: CGFloat { Metrics.sidebarRowHeight - Metrics.space1 }
    /// The SF Symbol it draws, or a custom glyph name ``customImage`` draws.
    public var symbol: String {
        didSet { if symbol != oldValue { renderedIconSize = 0; renderSymbol() } }
    }
    /// Draws a custom glyph name at a point size, or nil for an SF Symbol (the sidebar toggle's
    /// candidates, `SidebarToggleIcon.image(named:pointSize:)`).
    public var customImage: ((String, CGFloat) -> NSImage?)? {
        didSet { renderedIconSize = 0; renderSymbol() }
    }
    private var renderedIconSize: CGFloat = 0
    public private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// Set once `hover` follows the pointer (not during NSButton's init).
    private var followsPointer = false
    /// True from a mouse-down that may become a long press until its mouse-up or its deadline.
    private(set) var isHoldingForMenu = false

    public init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        // A collapsing band narrows its items: the glyph scales down with them.
        imageScaling = .scaleProportionallyDown
        renderSymbol()
        contentTintColor = performWithTheme { Palette.textSecondary }
        // Hover follows the pointer and the button's frame (cx-3wu5): a band
        // that collapses or hides under a still pointer clears it.
        hover.followPointer(isHoverable: { [weak self] in self?.isEnabled ?? false })
        followsPointer = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var mouseDownCanMoveWindow: Bool { false }

    /// Disabled under a still pointer (Back with no history left): hover
    /// follows at once (cx-3wu5).
    override public var isEnabled: Bool {
        didSet { if followsPointer, isEnabled != oldValue { hover.pointer?.refresh() } }
    }

    override public func layout() {
        super.layout()
        renderSymbol()
    }

    private func renderSymbol() {
        let size = Metrics.smallIconSize
        guard size != renderedIconSize else { return }
        renderedIconSize = size
        image = customImage?(symbol, size)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    /// A right-click or long-press menu (Back / Forward lists); the sidebar toggle's opens on right-click only.
    public var menuProvider: (() -> NSMenu?)?, longPressOpensMenu = true
    /// The long press's deadline (a press still held when it fires shows the menu); with none a press is a click.
    public var longPressDeadline: (any LongPressDeadline)?
    /// A menu that opens on press, like a pop-up button (the pane toolbar's "…"): press, drag
    /// to a row and release to run it; a plain click leaves it open. The action still runs
    /// for a keyboard or VoiceOver press.
    public var pressMenu: (() -> NSMenu?)?
    /// Shows a menu under the button (tests record it instead).
    public var presentMenu: @MainActor (NSMenu, TitlebarBandButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: button, gap: Metrics.space1), in: button)
    }

    /// Told `true` as a menu this button opened (press, long-press or right-click) shows and
    /// `false` once it closes, so a host that fades the button on hover keeps it revealed while
    /// its menu is open (Leo, 2026-10-26: a hover-revealed control stays revealed and lit while
    /// the menu it opened is open).
    public var onMenuOpenChange: ((Bool) -> Void)?

    /// Shows `menu` with the button pressed (lit) for as long as it is open.
    private func showMenu(_ show: () -> Void) {
        isHighlighted = true
        hover.state.pressed = true
        onMenuOpenChange?(true)
        defer {
            isHighlighted = false
            hover.state.pressed = false
            onMenuOpenChange?(false)
        }
        show()
    }

    /// Opens the press menu for keyboard and VoiceOver activation. Mouse presses
    /// use the same path from ``mouseDown(with:)``.
    public func performPressMenu() {
        guard isEnabled, let menu = pressMenu?(), !menu.items.isEmpty else { return }
        showMenu { presentMenu(menu, self) }
    }

    override public func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        guard pressMenu != nil else { return sendAction(action, to: target) }
        performPressMenu()
        return true
    }

    override public func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        showMenu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    /// A long press shows the menu like a browser's Back button; a click runs.
    override public func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if pressMenu != nil {
            performPressMenu()
            return
        }
        guard menuProvider != nil, longPressOpensMenu, let longPressDeadline, window != nil else {
            return super.mouseDown(with: event)
        }
        // The release or the deadline decides; no modal loop holds the run loop meanwhile (Chrome's
        // ToolbarButton posts its drop-down menu as a delayed task on press, chrome/browser/ui/views/toolbar/toolbar_button.cc).
        isHoldingForMenu = true
        longPressDeadline.schedule(after: .seconds(NSEvent.doubleClickInterval)) { [weak self] in
            self?.longPressDeadlinePassed()
        }
    }

    /// Held through the deadline: the menu instead of the action.
    private func longPressDeadlinePassed() {
        guard isHoldingForMenu, window != nil else { return }
        isHoldingForMenu = false
        if let menu = menuProvider?() { showMenu { presentMenu(menu, self) } }
    }

    /// The hold's drags move nothing (as the press always took them).
    // input-coalesce: native (a held press drops its drags; otherwise NSButton's own tracking)
    override public func mouseDragged(with event: NSEvent) {
        guard !isHoldingForMenu else { return }
        super.mouseDragged(with: event)
    }

    /// Released before the deadline, anywhere: a click.
    override public func mouseUp(with event: NSEvent) {
        guard isHoldingForMenu else { return super.mouseUp(with: event) }
        endHold()
        sendAction(action, to: target)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Out of the window, the hold's mouse-up never comes here.
        if window == nil { endHold() }
    }

    private func endHold() {
        isHoldingForMenu = false
        longPressDeadline?.cancel()
    }
}
