public import AppKit
import CmuxNextDesignTokens

/// An icon button of the toolbar band and the pane's tab bar controls: the chrome's hover and
/// pressed look.
public final class TitlebarBandButton: ClickableButton {
    /// The top row's button size (``TopRowSpacing/buttonSide``): the top-left band and the sidebar's + draw at it. A
    /// pane's tab row draws its tools a tab tall instead (``Metrics/tabBarControlSide``, Lawrence 2026-11-23).
    public static var side: CGFloat { TopRowSpacing.buttonSide }
    /// The SF Symbol it draws, or a custom glyph name ``customImage`` draws.
    public var symbol: String {
        didSet { if symbol != oldValue { renderedIconSize = 0; renderSymbol() } }
    }
    /// Draws a custom glyph name at a point size, or nil for an SF Symbol (the sidebar toggle's
    /// candidates, `SidebarToggleIcon.image(named:pointSize:)`).
    public var customImage: ((String, CGFloat) -> NSImage?)? {
        didSet { renderedIconSize = 0; renderSymbol() }
    }
    /// Optional short text shown beside the symbol. A nil value preserves the icon-only control.
    public var text: String? {
        didSet {
            guard text != oldValue else { return }
            applyText()
            needsLayout = true
        }
    }
    /// Optional compact count/status text supplied by a content-owned tool.
    public var badge: String? {
        didSet { badgeLabel.stringValue = badge ?? ""; badgeLabel.isHidden = badge == nil; needsLayout = true }
    }
    /// The glyph's point size, read at layout so density changes apply live; nil draws at
    /// `Metrics.toolbarSymbolPointSize`, the top controls' one size (a split button's menu indicator draws smaller).
    public var symbolPointSize: (() -> CGFloat)? {
        didSet { renderedIconSize = 0; renderSymbol() }
    }
    /// A tool in a pane's tab row (beside the tab bar's + and the pane's ⋮): its hover fill rounds as a tab pill
    /// (``Metrics/tabBarControlCornerRadius(fitting:)``), as they do; off, it keeps the band's proportional corner.
    public var roundsAsTabBarControl = false {
        didSet { if roundsAsTabBarControl != oldValue { needsLayout = true } }
    }
    private let badgeLabel = NSTextField(labelWithString: "")
    private var renderedIconSize: CGFloat = 0
    public private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// Set once `hover` follows the pointer (not during NSButton's init).
    private var followsPointer = false

    public init(symbol: String, text: String? = nil) {
        self.symbol = symbol
        self.text = text
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        // A collapsing band narrows its items: the glyph scales down with them.
        imageScaling = .scaleProportionallyDown
        applyText()
        renderSymbol()
        // The glyph keeps its own ink while disabled: AppKit's dimming took it under 2:1; the tertiary
        // text is the disabled ink, which holds the legible floor (NativeControlContrastAuditTests).
        (cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        applyInk()
        badgeLabel.font = Typography.caption
        badgeLabel.alignment = .center
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
        didSet {
            if followsPointer, isEnabled != oldValue { hover.pointer?.refresh() }
            applyInk()
        }
    }

    // The ink is read in the button's own theme scope (a workspace's theme, not only the app's) when it
    // joins a window, on every theme change and when it shows: read once at init it kept the app
    // theme's gray (#bfc0c3) in every room, 1.3 to 2.6:1 on light and tinted themes.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyInk()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyInk()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        applyInk()
    }

    /// Secondary text at rest, tertiary while disabled, in the button's scope; on a popover's glass each fit to the
    /// glass over any page (``NSView/glassInk(_:minimum:)``: 2.01:1 and, disabled, 1.35:1 over a black page before).
    private func applyInk() {
        performWithTheme {
            let secondary = glassInk(\.textSecondary, minimum: CmuxDialogButtonLook.minimumContrast) ?? Palette.textSecondary
            contentTintColor = isEnabled ? secondary
                : glassInk(\.textTertiary, minimum: CmuxDialogButtonLook.disabledMinimumContrast) ?? Palette.textTertiary
            badgeLabel.textColor = secondary
        }
    }

    override public func layout() {
        super.layout()
        renderSymbol()
        // The hover fill is the button's own layer, rounded by the tab's ratio on its own height, so it keeps one
        // shape at every density (Lucas 2026-11-15: the tab's radius on a smaller button went nearly round at Spacious);
        // in a tab row, as the tabs beside it (Lawrence 2026-11-20).
        layer?.cornerRadius = roundsAsTabBarControl ? Metrics.tabBarControlCornerRadius(fitting: bounds.size)
            : Metrics.buttonCornerRadius(proportionalTo: bounds.height)
        let size = min(Metrics.space3, bounds.height)
        badgeLabel.frame = NSRect(x: bounds.maxX - size, y: bounds.maxY - size, width: size, height: size)
    }

    /// The width needed for the control's current symbol and optional text.
    /// Text is still middle-truncated by the button cell when its frame is tighter.
    /// A tab-row tool (``roundsAsTabBarControl``) is a tab tall and as wide (``Metrics/tabBarControlSide``); the band's
    /// are the top row's (``side``).
    public var preferredWidth: CGFloat {
        let side = roundsAsTabBarControl ? Metrics.tabBarControlSide : Self.side
        guard let text, !text.isEmpty else { return side }
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: Typography.caption]).width)
        let badgeClearance = badge == nil ? 0 : Metrics.space3 + Metrics.space1
        return side + Metrics.space2 + textWidth + Metrics.space2 + badgeClearance
    }

    /// Draws the glyph at the current density's size, once per size. `layout()` runs it; a container that measures the
    /// image (the toolbar band's slots) runs it first, since its own layout comes before this button's.
    public func renderSymbol() {
        let size = symbolPointSize?() ?? Metrics.toolbarSymbolPointSize
        guard size != renderedIconSize else { return }
        renderedIconSize = size
        image = customImage?(symbol, size)
            ?? NSImage.packOverride(forSymbol: symbol, pointSize: size)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: Metrics.toolbarSymbolWeight))
    }

    private func applyText() {
        guard let text, !text.isEmpty else {
            title = ""
            imagePosition = .imageOnly
            return
        }
        title = text
        font = Typography.caption
        imagePosition = .imageLeft
        alignment = .center
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.lineBreakMode = .byTruncatingMiddle
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

    /// The right-click (and Control-click) menu opens while the button is disabled too (Back
    /// with nowhere to go still lists Recently Closed); its click and long press stay off.
    public var opensMenuWhenDisabled = false
    /// Shows the right-click menu (tests record it instead).
    public var presentContextMenu: @MainActor (NSMenu, NSEvent, TitlebarBandButton) -> Void = { menu, event, button in
        NSMenu.popUpContextMenu(menu.withoutSystemItems(), with: event, for: button)
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
        guard isEnabled || opensMenuWhenDisabled else { return }
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        showMenu { presentContextMenu(menu, event, self) }
    }

    /// A long press shows the menu like a browser's Back button; a click runs.
    override public func mouseDown(with event: NSEvent) {
        // Control-click is a right-click: a disabled button may still open its menu.
        if event.modifierFlags.contains(.control), menuProvider != nil, pressMenu == nil {
            return rightMouseDown(with: event)
        }
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
