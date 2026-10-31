public import AppKit

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
    /// Optional compact count/status text supplied by a content-owned tool.
    public var badge: String? {
        didSet { badgeLabel.stringValue = badge ?? ""; badgeLabel.isHidden = badge == nil; needsLayout = true }
    }
    /// The glyph's point size, read at layout so density changes apply live; nil draws at
    /// `Metrics.smallIconSize` (a split button's menu indicator draws smaller).
    public var symbolPointSize: (() -> CGFloat)? {
        didSet { renderedIconSize = 0; renderSymbol() }
    }
    private let badgeLabel = NSTextField(labelWithString: "")
    private var renderedIconSize: CGFloat = 0
    public private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// Set once `hover` follows the pointer (not during NSButton's init).
    private var followsPointer = false

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
        badgeLabel.font = Typography.caption
        badgeLabel.alignment = .center
        badgeLabel.textColor = performWithTheme { Palette.textSecondary }
        badgeLabel.isBezeled = false
        badgeLabel.drawsBackground = false
        badgeLabel.isEditable = false
        badgeLabel.isSelectable = false
        badgeLabel.isHidden = true
        addSubview(badgeLabel)
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
        let size = min(Metrics.space3, bounds.height)
        badgeLabel.frame = NSRect(x: bounds.maxX - size, y: bounds.maxY - size, width: size, height: size)
    }

    private func renderSymbol() {
        let size = symbolPointSize?() ?? Metrics.smallIconSize
        guard size != renderedIconSize else { return }
        renderedIconSize = size
        image = customImage?(symbol, size)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    /// A right-click or long-press menu (Back / Forward lists); the sidebar toggle's opens on right-click only.
    public var menuProvider: (() -> NSMenu?)?, longPressOpensMenu = true
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
        guard menuProvider != nil, longPressOpensMenu, let window else { return super.mouseDown(with: event) }
        let deadline = Date().addingTimeInterval(NSEvent.doubleClickInterval)
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { sendAction(action, to: target); return }
        }
        if let menu = menuProvider?() { showMenu { presentMenu(menu, self) } }
    }
}
