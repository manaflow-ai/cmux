public import AppKit
public import CmuxNextIcons
import CmuxNextDesignTokens

/// The app's one more ("overflow") button: a vertical ellipsis (⋮, the pack's `action.more.vertical`),
/// like Chrome's menu button (Leo 2026-10-20). Every more button uses it, so the glyph, its size and
/// the chrome's hover and pressed look are the same in the sidebar, pane toolbars and cards; the host
/// gives it the frame of its row of buttons and says what a press does.
public final class OverflowButton: ClickableButton {
    /// The glyph every more button draws.
    public static let glyph: IconName = .actionMoreVertical
    /// The glyph's point size, read at layout time so density changes apply live.
    public static var glyphSize: CGFloat { .iconRowSize(forLabelPointSize: Metrics.smallIconSize - Metrics.space1) }
    /// A pane's ⋮, on its tab bar and its browser toolbar alike (Lawrence msg 19627: one ⋮ in the pane): Chrome's and
    /// Helium's 3 dots (`browser.toolbar.more`), 12 pt tall at Compact and Default (Lucas 2026-11-18).
    public static let paneGlyph: IconName = .browserToolbarMore
    /// ``paneGlyph``'s side: the density's `omnibarMoreGlyphSize` (Compact's and Default's 20 pt), else ``glyphSize``.
    public static var paneGlyphSize: CGFloat { Metrics.densityToken("omnibarMoreGlyphSize") ?? glyphSize }
    /// Draws ``paneGlyph`` at ``paneGlyphSize`` instead of the app's ⋮ (a pane's tab bar). Its side may pass a small
    /// button, but its dots fit inside, so it draws at full size in ``paneGlyphView``, its ink centered on whole pixels:
    /// the button's cell would shrink an image larger than its image area.
    public var drawsPaneGlyph = false {
        didSet {
            guard drawsPaneGlyph != oldValue else { return }
            renderedSize = 0
            renderGlyph()
            needsLayout = true
        }
    }
    /// The ⋮ image the button draws: its own, or ``paneGlyphView``'s for the pane glyph.
    public var drawnGlyph: NSImage? { drawsInGlyphView ? paneGlyphViewIfMade?.glyph : image }
    /// The glyph draws in ``paneGlyphView``: the pane glyph, and any glyph while disabled, which AppKit would fade in
    /// the button's own image whatever its cell says (Hot Dog Stand's dark ⋮ read at half alpha, 2.39:1 on its red).
    private var drawsInGlyphView: Bool { drawsPaneGlyph || !isEnabled }
    /// Made on first use, so the sidebar's and the cards' ⋮ get no extra view.
    private var paneGlyphViewIfMade: InkCenteredGlyphView?
    private var paneGlyphView: InkCenteredGlyphView {
        if let paneGlyphViewIfMade { return paneGlyphViewIfMade }
        let view = InkCenteredGlyphView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        paneGlyphViewIfMade = view
        return view
    }

    public private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// What a click or VoiceOver's press does (the sidebar row's menu, the group editor).
    public var onPress: (() -> Void)?
    /// A menu that opens on press, like a pop-up button (the pane toolbar's): press, drag to a row
    /// and release to run it. VoiceOver's press runs ``onPress``, else opens this menu.
    public var pressMenu: (() -> NSMenu?)?
    /// Shows a press menu under the button (tests record it instead).
    public var presentMenu: @MainActor (NSMenu, OverflowButton) -> Void = { menu, button in
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: button, gap: Metrics.space1), in: button)
    }
    /// The button's right-click menu; nil keeps AppKit's.
    public var menuProvider: (() -> NSMenu?)?
    /// A fixed glyph color on a colored surface (a group header's ink); nil uses the secondary
    /// text color, primary while hovered or pressed.
    public var tintOverride: NSColor? { didSet { if tintOverride != oldValue { needsDisplay = true } } }
    /// What the button opens, for VoiceOver and the themed tooltip.
    public var label: String {
        didSet {
            guard label != oldValue else { return }
            setAccessibilityLabel(label)
            themedToolTip = label
            image?.accessibilityDescription = label
        }
    }
    /// The menu, popover or editor this button opened is open: the button stays shown pressed (lit)
    /// after the pointer leaves it, until the host clears it as that closes (Leo 2026-10-26: "you keep it
    /// on when you click the context menu ... the drop-down, the popover"). Only the button lights,
    /// never the row it sits on (Leo 2026-10-27: "Just don't do that. Don't ever do that.").
    public var showsMenu = false {
        didSet { if showsMenu != oldValue { changeHover { $0.pressed = showsMenu } } }
    }
    /// The hover look (``ChromeHoverStyle``): a rounded plate by default; the pane tab bar's ⋮ takes the tab bar's
    /// style so it matches the + and chevron beside it.
    public var hoverStyle: ChromeHoverStyle = .plate {
        didSet {
            guard hoverStyle != oldValue else { return }
            hover.paintsFill = hoverStyle.paintsFill
            needsDisplay = true
        }
    }
    /// The plate's corner radius where the host knows the corner the button rests in (the pane tab
    /// bar's ⋮ in the card's top-trailing corner: concentric with it, the card's radius less the
    /// button's inset); nil: the button radius, a tab's (``Metrics/buttonCornerRadius``). A circle ignores it.
    public var plateCornerRadius: CGFloat? {
        didSet { if plateCornerRadius != oldValue { needsDisplay = true } }
    }
    private var renderedSize: CGFloat = 0
    /// The ⋮'s side where the host sizes it with the controls beside it (a sidebar row's, `SidebarStyle.rowSymbolSide`);
    /// nil draws ``glyphSize``. Read at layout time so density changes apply live.
    public var glyphSide: (() -> CGFloat)? {
        didSet {
            renderedSize = 0
            renderGlyph()
            needsLayout = true
        }
    }

    public init(label: String) {
        self.label = label
        super.init(frame: .zero)
        // An image-only button: no "Button" title for VoiceOver and hint mode (they read the label).
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel(label)
        themedToolTip = label
        wantsLayer = true
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
        focusRingType = .none
        renderGlyph()
        // Hover follows the pointer and the button's frame (cx-3wu5).
        hover.followPointer(onChange: { [weak self] in self?.needsDisplay = true })
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var mouseDownCanMoveWindow: Bool { false }

    override public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            renderedSize = 0
            renderGlyph()
            needsLayout = true
            needsDisplay = true
        }
    }

    @objc private func pressed() { onPress?() }

    /// AXPress runs `onPress` and reports success (NSButton's own press answered -25205, so an
    /// agent that read the error pressed again).
    override public func accessibilityPerformPress() -> Bool {
        guard onPress != nil || pressMenu != nil else { return super.accessibilityPerformPress() }
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        if let onPress {
            onPress()
        } else if let menu = pressMenu?(), !menu.items.isEmpty {
            presentMenu(menu, self)
        }
        return true
    }

    override public func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    private func renderGlyph() {
        let size = drawsPaneGlyph ? Self.paneGlyphSize : glyphSide?() ?? Self.glyphSize
        guard size != renderedSize else { return }
        renderedSize = size
        let image = NSImage.icon(drawsPaneGlyph ? Self.paneGlyph : Self.glyph, size: size)
        image.accessibilityDescription = label
        if drawsInGlyphView {
            self.image = nil
            paneGlyphView.glyph = image
            paneGlyphView.isHidden = false
        } else {
            self.image = image
            paneGlyphViewIfMade?.isHidden = true
        }
    }

    override public func layout() {
        super.layout()
        renderGlyph()
        if drawsInGlyphView { paneGlyphView.frame = bounds }
    }

    nonisolated override public var wantsUpdateLayer: Bool { true }

    override public func updateLayer() {
        let side = min(bounds.width, bounds.height)
        // The opt-in circle look (ChromeHoverStyle.circle) is a circle; every other plate takes the tab's ratio on its
        // own side (Lucas 2026-11-15: one shape at every density), or the concentric plate a set corner gives it.
        layer?.cornerRadius = hoverStyle == .circle ? side / 2 // radius-allow: circle look
            : min(plateCornerRadius ?? Metrics.buttonCornerRadius(proportionalTo: side), side / 2)
        performWithTheme {
            // Without a fill, a press or an open menu shows in the glyph's own ink, as the tab bar's + does.
            let pressedInk = hoverStyle == .glyph ? Palette.litGlyph : Palette.textPrimary
            contentTintColor = !isEnabled ? disabledInk
                : tintOverride ?? (hover.state.pressed ? pressedInk : hover.state.hovering ? Palette.textPrimary : Palette.textSecondary)
            if drawsInGlyphView { paneGlyphView.contentTintColor = contentTintColor }
        }
        hover.refresh(animated: false)
    }

    /// The disabled glyph's ink, not AppKit's faded glyph (over a see-through window it read 1.45:1, Nord Light;
    /// NativeControlContrastAuditTests): the tertiary text, moved toward its pole until it reads at
    /// ``disabledGlyphContrast`` on what the button sits on (``NSView/buttonGround(_:)``). Runs inside `performWithTheme`.
    private var disabledInk: NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let ground = buttonGround(tokens)
        return CmuxDialogButtonLook.readable(tokens.textTertiary.composited(over: ground[0]), over: ground,
                                             minimum: Self.disabledGlyphContrast).nsColor
    }

    /// The disabled ⋮'s ink contrast. Its dots are about two pixels across, so no pixel of them is full ink: an ink at
    /// 3:1 showed at 2.39:1 on screen (Hot Dog Stand) and the tertiary text, 3.57:1, at 2.48:1 (a dark popup surface).
    /// 4:1 keeps the dots at the 2.5:1 legible floor, still a step under the enabled glyph's secondary ink (4.5:1).
    static let disabledGlyphContrast = 4.0

    private func changeHover(_ change: (inout ChromeHover.State) -> Void) {
        change(&hover.state)
        needsDisplay = true
    }

    /// A press menu opens on mouse-down, pressed while it is open; otherwise NSButton tracks the
    /// click inside `super.mouseDown` and returns on release.
    override public func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        changeHover { $0.pressed = true }
        defer { changeHover { [showsMenu] in $0.pressed = showsMenu } }
        if let pressMenu {
            guard let menu = pressMenu(), !menu.items.isEmpty else { return }
            presentMenu(menu, self)
            return
        }
        super.mouseDown(with: event)
    }

    /// A button hidden under the pointer (a row's hover controls) gets no exit event: the hover
    /// owner clears it, and it shows again with the hover the pointer gives it then.
    override public func viewDidHide() {
        super.viewDidHide()
        changeHover { [showsMenu] in $0.pressed = showsMenu }
        hover.pointer?.refresh()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        hover.pointer?.refresh()
    }
}
