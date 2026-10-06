import AppKit
import CmuxNextDesign
import QuartzCore

/// The footer's "Update Ready" pill (SIDEBAR-FOOTER-MINIMAL): a restart glyph
/// and a label on a neutral capsule (the theme's hover fill, primary text;
/// never the accent, never blue). One click installs and relaunches; its
/// tooltip and VoiceOver label say that terminals and agents keep running.
/// While the update installs it stays, disabled. A button for VoiceOver, and
/// for the keyboard with Full Keyboard Access on.
final class SidebarUpdatePillView: NSView {
    var onPress: (() -> Void)?
    private(set) var pill: SidebarUpdatePill?
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
    /// Glyph only (the label is hidden) when the line has no room for it.
    var isCompact = false { didSet { if isCompact != oldValue { label.isHidden = isCompact; needsLayout = true } } }

    static let symbol = "arrow.clockwise"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        glyph.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        [glyph, label].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows `pill`, or hides the view for nil.
    func configure(_ pill: SidebarUpdatePill?) {
        guard pill != self.pill else { return }
        self.pill = pill
        isHidden = pill == nil
        label.stringValue = pill?.title ?? ""
        toolTip = pill?.help
        setAccessibilityLabel(pill?.help)
        setAccessibilityEnabled(pill?.isEnabled ?? false)
        if pill?.isEnabled != true { isPressed = false }
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Geometry

    static var height: CGFloat { Metrics.sidebarRowHeight - Metrics.space2 }
    private static var font: NSFont { .systemFont(ofSize: Typography.caption.pointSize, weight: .medium) }
    private static var glyphSize: CGFloat { Metrics.smallIconSize - Metrics.space1 }

    /// The capsule's width: padding, glyph, gap, label, padding; a circle
    /// (glyph only) when `compact`.
    func width(compact: Bool) -> CGFloat {
        guard !compact, let pill else { return Self.height }
        let text = (pill.title as NSString).size(withAttributes: [.font: Self.font]).width
        return ceil(Metrics.space2 + Self.glyphSize + Metrics.space1 + text + Metrics.space3)
    }

    override func layout() {
        super.layout()
        let b = bounds
        layer?.cornerRadius = b.height / 2
        label.font = Self.font
        let side = Self.glyphSize
        glyph.image = NSImage(systemSymbolName: Self.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side, weight: .semibold))
        let glyphX = isCompact ? (b.width - side) / 2 : Metrics.space2
        glyph.frame = NSRect(x: glyphX, y: (b.height - side) / 2, width: side, height: side)
        let th = ceil(label.intrinsicContentSize.height)
        let textX = glyph.frame.maxX + Metrics.space1
        label.frame = NSRect(x: textX, y: (b.height - th) / 2, width: max(0, b.width - textX - Metrics.space2), height: th)
    }

    /// The capsule's fill: neutral at rest, one tonal step under the pointer
    /// or keyboard focus, pressed while held.
    var fill: NSColor {
        performWithTheme {
            if isPressed { return Palette.pressedFill }
            if (isHovered || isKeyFocused), pill?.isEnabled == true { return Palette.selectionFill }
            return Palette.hoverFill
        }
    }

    override func updateLayer() {
        let enabled = pill?.isEnabled == true
        performWithTheme {
            layer?.backgroundColor = fill.cgColor
            let text = enabled ? Palette.textPrimary : Palette.textSecondary
            label.textColor = text
            glyph.contentTintColor = text
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    override func mouseDown(with event: NSEvent) {
        guard pill?.isEnabled == true else { return }
        isPressed = true
    }

    /// Acts on release inside, like a button.
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    /// A click (tests, VoiceOver, Space or Return): sends once while enabled.
    func press() {
        guard pill?.isEnabled == true else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard pill?.isEnabled == true else { return false }
        press()
        return true
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled && pill != nil }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        isKeyFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isKeyFocused = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
              [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        press()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    // MARK: Tests

    /// The label as drawn ("" while compact).
    var shownTitle: String { label.isHidden ? "" : label.stringValue }
}
