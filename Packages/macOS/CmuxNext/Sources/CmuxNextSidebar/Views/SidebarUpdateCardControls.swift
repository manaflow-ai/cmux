public import CmuxNextDesign
import CmuxNextIcons
import AppKit
import QuartzCore

/// The fill of the update card's Restart to Update button (Debug Settings
/// `sidebar.updateCard.button`, the UPDATE-CARD prototype switch; Lawrence
/// picks one). Every variant is a theme token, never the system blue.
public nonisolated enum SidebarUpdateButtonStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The app's primary action (the default, Leo 2026-10-20: "give Restart to Update the primary
    /// button style"): the theme's accent fill and its ink (`Palette.accentFill` / `onAccent`, the
    /// selected menu row's pair), emphasized text. With no chosen accent (`accentFill` is then the
    /// primary text, a white slab on a dark card) it is the dialogs' prominent neutral button
    /// instead: the selection fill with the primary text (2026-10-22, "just make it look better").
    case primary
    /// The app's button (the default until 2026-10-20, Leo 2026-10-19: no light slab): the
    /// hover fill with a hairline edge and the primary text, as the Updated
    /// card's See What's New and every themed popover button.
    case bordered
    /// The theme's foreground as the fill, its background as the text: the
    /// strongest neutral call to action.
    case inverted
    /// The app accent (`Palette.accent`, the theme's grays).
    case accent
    /// The theme's own accent color (`Palette.highlight`) when the theme
    /// names one, else inverted.
    case themeAccent

    public var tunableTitle: String {
        switch self {
        case .primary: "Primary"
        case .bordered: "App button"
        case .inverted: "Inverted"
        case .accent: "App accent"
        case .themeAccent: "Theme accent"
        }
    }
}

/// How the Update Ready card lays out its one action, Restart to Update (Leo 2026-11-07, once
/// updates download by themselves: "we're gonna need a more, probably a more prominent sort of
/// button or something"; #39682). Three directions for the gallery
/// (`AARestartToUpdateGalleryTests`); `card` stays the default until one is picked.
public nonisolated enum SidebarUpdateCardLayout: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// Title and Hide, the version, the Automatic Updates switch, then a full-width Restart to Update.
    case card
    /// Title and Hide, then the version beside a Restart to Update sized to its words: two rows.
    case compact
    /// Restart to Update alone, full width, the version under it; Hide is on the right-click menu.
    case button

    public var tunableTitle: String {
        switch self {
        case .card: "Card"
        case .compact: "Compact"
        case .button: "Button only"
        }
    }
}

nonisolated extension SidebarTunables {
    public static let updateCardLayout = Tunable<SidebarUpdateCardLayout>.choice(
        "sidebar.updateCard.layout", .sidebar, "Update card layout",
        help: "How the Update Ready card lays out Restart to Update (card, compact, button only).",
        default: .card, code: "SidebarTunables.updateCardLayout")

    public static let updateCardButton = Tunable<SidebarUpdateButtonStyle>.choice(
        "sidebar.updateCard.button", .sidebar, "Update card button",
        help: "The fill of the update card's Restart to Update button (UPDATE-CARD prototype).",
        default: .primary, code: "SidebarTunables.updateCardButton")
}

/// The update card's full-width Restart to Update button: one click
/// installs and relaunches. Disabled (Installing…) once the click was
/// taken. A button for VoiceOver and Full Keyboard Access.
final class SidebarUpdateButton: NSView {
    var onPress: (() -> Void)?
    private(set) var isEnabled = true
    /// A secondary button (the tip card's Try It): the hover fill and the
    /// primary text, never the call-to-action fill.
    var isQuiet = false { didSet { if isQuiet != oldValue { needsDisplay = true } } }
    /// A fixed fill (the notice card's prominent action keeps ``SidebarUpdateButtonStyle/inverted``);
    /// nil follows `sidebar.updateCard.button` (the update card).
    var fixedStyle: SidebarUpdateButtonStyle? { didSet { if fixedStyle != oldValue { needsLayout = true; needsDisplay = true } } }
    /// The fill this button draws.
    var style: SidebarUpdateButtonStyle { fixedStyle ?? SidebarTunables.updateCardButton.value }
    /// The app's button (hairline edge, regular weight, popup row corners) rather than a call-to-action slab.
    private var isBordered: Bool { !isQuiet && style == .bordered }
    private let label = ChromeLabel(labelWithString: "")
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    /// Full Keyboard Access focus: a ring in the theme's focus color, not the system's blue.
    private var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
    private var showsKeyFocus: Bool { KeyWindowRepaint.showsFocus(self, focused: isKeyFocused) }
    private lazy var keyRepaint = KeyWindowRepaint(self)
    /// A pointer press before this moment (`NSEvent.timestamp`, seconds since boot) is ignored:
    /// the button just took the place of another card's (``ignorePointer(for:)``). Keys and
    /// VoiceOver are never ignored. A stored deadline, no timer: nothing to stop or clean up.
    private var ignoresPointerUntil: TimeInterval = 0

    /// How long a button that just appeared under the pointer ignores presses: long enough for a
    /// click already on its way to the card it replaced, short enough for a deliberate one.
    static let appearGuard: TimeInterval = 1

    /// Ignores pointer presses for `duration` from now: the button just replaced another one
    /// under the pointer, so a click meant for that one must not land on this.
    func ignorePointer(for duration: TimeInterval = SidebarUpdateButton.appearGuard,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        ignoresPointerUntil = now + duration
        isPressed = false
    }

    /// Whether a pointer press at `timestamp` (an `NSEvent.timestamp`) is ignored.
    func ignoresPointer(at timestamp: TimeInterval) -> Bool { timestamp < ignoresPointerUntil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        focusRingType = .none
        layer?.cornerCurve = .continuous
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The app's control height (the Updated card's button, 24 pt at the default spacing).
    static var height: CGFloat { Metrics.sidebarRowHeight - Metrics.space1 }
    static var font: NSFont { font(bordered: false) }
    static func font(bordered: Bool) -> NSFont {
        Typography.system(size: Typography.caption.pointSize, weight: bordered ? TypeScale.regular : TypeScale.emphasis)
    }

    /// The width that fits the label on one line with the button's inset (the compact layout).
    var fittingWidth: CGFloat {
        let font = Self.font(bordered: isBordered)
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 2 * Metrics.space2
    }

    func configure(title: String, enabled: Bool, help: String?) {
        label.stringValue = title
        isEnabled = enabled
        if !enabled { isPressed = false }
        setAccessibilityLabel(title)
        setAccessibilityHelp(help)
        setAccessibilityEnabled(enabled)
        needsLayout = true
        needsDisplay = true
    }

    /// The label as drawn.
    var title: String { label.stringValue }

    override func layout() {
        super.layout()
        layer?.cornerRadius = isBordered ? Metrics.controlCornerRadius : Metrics.insetCornerRadius
        label.font = Self.font(bordered: isBordered)
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: Metrics.space2, y: (bounds.height - h) / 2, width: max(0, bounds.width - 2 * Metrics.space2), height: h)
    }

    /// The fill and text colors of `style` (theme-scoped: call inside
    /// `performWithTheme`).
    static func colors(_ style: SidebarUpdateButtonStyle) -> (fill: NSColor, text: NSColor) {
        switch style {
        case .primary where !Palette.hasChosenAccent: (Palette.selectionFill, Palette.textPrimary)
        case .primary: (Palette.accentFill, Palette.onAccent)
        case .bordered: (Palette.hoverFill, Palette.textPrimary)
        case .themeAccent where Palette.hasThemeAccent: (Palette.highlight, Palette.highlightText)
        case .accent: (Palette.accent, Palette.textPrimary)
        case .inverted, .themeAccent: (Palette.textPrimary, Palette.textOnPrimary)
        }
    }

    /// The primary style in a theme with no chosen accent: the prominent neutral, not the accent
    /// pair (theme-scoped: read inside `performWithTheme`).
    private var isNeutralPrimary: Bool { !isQuiet && style == .primary && !Palette.hasChosenAccent }

    /// The fill now: the style's color, a step lighter under the pointer,
    /// darker while held, faded while disabled.
    var fill: NSColor {
        performWithTheme {
            let neutral = isQuiet || style == .bordered
            let base = isQuiet ? Palette.hoverFill : Self.colors(style).fill
            // The neutral primary (no chosen accent) steps to the pressed fill under the pointer, as
            // the dialogs' prominent button does; fading a translucent fill would only wash it out.
            if isNeutralPrimary, isEnabled, isHovered || isPressed { return Palette.pressedFill }
            if !isEnabled, neutral { return base.withAlphaComponent(0.5) }
            if neutral, isPressed { return Palette.pressedFill }
            // Over its resting hover fill, the neutral step, never the accent selection.
            if neutral, isHovered { return ChromeHover.raisedHoverFill }
            // Scaled, not set: a translucent fill (the neutral primary) set to 0.4 got brighter.
            if !isEnabled { return base.withAlphaComponent(base.alphaComponent * 0.4) }
            if isPressed { return base.withAlphaComponent(0.75) }
            return isHovered ? base.withAlphaComponent(0.88) : base
        }
    }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = fill.cgColor
            let bordered = isBordered
            layer?.borderColor = (showsKeyFocus ? Palette.focusRing : Palette.separator).cgColor
            layer?.borderWidth = showsKeyFocus ? Metrics.lineWidth(1.5) : bordered ? Metrics.lineWidth(1) : 0
            let text = isQuiet ? Palette.textPrimary : Self.colors(style).text
            label.textColor = isEnabled || !(bordered || isNeutralPrimary) ? text : Palette.textSecondary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) { if isEnabled, !ignoresPointer(at: event.timestamp) { isPressed = true } }

    /// Acts on release inside, like a button.
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    /// A click (tests, VoiceOver, Space or Return): sends once while enabled.
    func press() {
        guard isEnabled else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        press()
        return true
    }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled && isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyRepaint.track()
    }

    override func becomeFirstResponder() -> Bool {
        isKeyFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isKeyFocused = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard SidebarUpdateToggle.isActivationKey(event) else { return super.keyDown(with: event) }
        press()
    }
}
