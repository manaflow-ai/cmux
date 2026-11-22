public import CmuxNextDesign
import AppKit
import QuartzCore

/// The fill of the update card's Restart to Update button (Debug Settings
/// `sidebar.updateCard.button`, the UPDATE-CARD prototype switch; Lawrence
/// picks one). Every variant is a theme token, never the system blue.
public nonisolated enum SidebarUpdateButtonStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
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
        case .inverted: "Inverted"
        case .accent: "App accent"
        case .themeAccent: "Theme accent"
        }
    }
}

nonisolated extension SidebarTunables {
    public static let updateCardButton = Tunable<SidebarUpdateButtonStyle>.choice(
        "sidebar.updateCard.button", .sidebar, "Update card button",
        help: "The fill of the update card's Restart to Update button (UPDATE-CARD prototype).",
        default: .inverted, code: "SidebarTunables.updateCardButton")
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
    private let label = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
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

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static var height: CGFloat { Metrics.sidebarRowHeight - Metrics.space1 }
    static var font: NSFont { .systemFont(ofSize: Typography.caption.pointSize, weight: .semibold) }

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
        layer?.cornerRadius = Metrics.space2
        label.font = Self.font
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: Metrics.space2, y: (bounds.height - h) / 2, width: max(0, bounds.width - 2 * Metrics.space2), height: h)
    }

    /// The fill and text colors of `style` (theme-scoped: call inside
    /// `performWithTheme`).
    static func colors(_ style: SidebarUpdateButtonStyle) -> (fill: NSColor, text: NSColor) {
        switch style {
        case .themeAccent where Palette.hasThemeAccent: (Palette.highlight, Palette.highlightText)
        case .accent: (Palette.accent, Palette.textPrimary)
        case .inverted, .themeAccent: (Palette.textPrimary, Palette.textOnPrimary)
        }
    }

    /// The fill now: the style's color, a step lighter under the pointer,
    /// darker while held, faded while disabled.
    var fill: NSColor {
        performWithTheme {
            let base = isQuiet ? Palette.hoverFill : Self.colors(SidebarTunables.updateCardButton.value).fill
            if isQuiet, isPressed { return Palette.pressedFill }
            if isQuiet, isHovered { return Palette.selectionFill }
            if !isEnabled { return base.withAlphaComponent(0.4) }
            if isPressed { return base.withAlphaComponent(0.75) }
            return isHovered ? base.withAlphaComponent(0.88) : base
        }
    }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = fill.cgColor
            label.textColor = isQuiet ? Palette.textPrimary : Self.colors(SidebarTunables.updateCardButton.value).text
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
    override func mouseDown(with event: NSEvent) { if isEnabled { isPressed = true } }

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
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.space2, yRadius: Metrics.space2).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard SidebarUpdateCheckbox.isActivationKey(event) else { return super.keyDown(with: event) }
        press()
    }
}

/// The update card's Automatic Updates checkbox, drawn in theme colors (a
/// system checkbox would draw the system accent). It shows the setting and
/// a click asks to change it; the box follows when the setting changes.
final class SidebarUpdateCheckbox: NSView {
    var onToggle: ((Bool) -> Void)?
    private(set) var isOn = false
    private let box = CALayer()
    private let mark = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        box.cornerCurve = .continuous
        box.borderWidth = 1
        layer?.addSublayer(box)
        mark.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        [mark, label].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static var font: NSFont { Typography.caption }
    static var boxSize: CGFloat { Metrics.smallIconSize - Metrics.space1 }
    static var height: CGFloat { max(boxSize, ceil(font.boundingRectForFont.height)) }

    func configure(title: String, isOn: Bool) {
        label.stringValue = title
        self.isOn = isOn
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
        needsLayout = true
        needsDisplay = true
    }

    /// The label as drawn.
    var title: String { label.stringValue }

    override func layout() {
        super.layout()
        let side = Self.boxSize, b = bounds
        label.font = Self.font
        let boxFrame = CGRect(x: 0, y: (b.height - side) / 2, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.frame = boxFrame
        box.cornerRadius = Metrics.space1
        CATransaction.commit()
        let inset = side * 0.18
        mark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side - 2 * inset, weight: .bold))
        mark.frame = boxFrame.insetBy(dx: inset, dy: inset)
        let th = ceil(label.intrinsicContentSize.height)
        let x = boxFrame.maxX + Metrics.space2
        label.frame = NSRect(x: x, y: (b.height - th) / 2, width: max(0, b.width - x), height: th)
    }

    override func updateLayer() {
        performWithTheme {
            box.backgroundColor = (isOn ? Palette.textPrimary : NSColor.clear).cgColor
            box.borderColor = (isOn ? Palette.textPrimary : Palette.textTertiary).cgColor
            mark.contentTintColor = Palette.textOnPrimary
            mark.isHidden = !isOn
            label.textColor = Palette.textSecondary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle()
    }

    /// A click: asks for the other state; the box changes when the setting does.
    func toggle() { onToggle?(!isOn) }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    override var focusRingMaskBounds: NSRect { box.frame }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: box.frame, xRadius: Metrics.space1, yRadius: Metrics.space1).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard Self.isActivationKey(event) else { return super.keyDown(with: event) }
        toggle()
    }

    /// Space or Return without modifiers.
    static func isActivationKey(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty
            && [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "")
    }
}
