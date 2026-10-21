import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A workspace row's hover action as a dog-ear: a page corner folded over the row's top-right
/// corner (Leo 2026-10-21: "just do it like dog ears on a book on the top right"). It replaces the
/// x and the menu button that sat at the end of the title in boxes of their own, which dented the
/// row's corner and took the end of its text.
///
/// The fold overlays the corner and reshapes nothing: the row keeps its one corner radius, and the
/// fold's right-angle corner follows that radius (`cornerRadius`). It takes clicks only inside the
/// triangle, so the rest of its square stays the row's (a click on the title's end selects, never
/// closes). Its fills are the theme's translucent hover and pressed fills over whatever the row
/// shows (glass, never an opaque slab), with a hairline crease in the separator color.
final class SidebarDogEarButton: NSButton {
    var onPress: (() -> Void)?
    /// The row's corner radius, which the fold's outer corner follows.
    var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue { needsDisplay = true } } }
    /// What a press does, for VoiceOver and the themed tooltip.
    var label: String {
        didSet {
            guard label != oldValue else { return }
            setAccessibilityLabel(label)
            themedToolTip = label
            image?.accessibilityDescription = label
        }
    }
    /// The pointer is on the fold (its triangle, not just its square): the stronger fill.
    var isPointerOnFold = false { didSet { if isPointerOnFold != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private let icon: IconName
    private var renderedSide: CGFloat = 0
    /// The glyph in the last tint drawn, so a redraw in the same colors makes no new image.
    private var tintedGlyph: (color: NSColor, image: NSImage)?
    private var tracking: NSTrackingArea?

    init(icon: IconName, label: String) {
        self.icon = icon
        self.label = label
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        setAccessibilityLabel(label)
        themedToolTip = label
        wantsLayer = true
        // Over the row's trailing marks, which keep their places under the fold.
        layer?.zPosition = 1
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
        focusRingType = .none
        renderGlyph()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func pressed() { onPress?() }

    /// AXPress runs `onPress` and reports success (NSButton's own press could answer
    /// kAXErrorActionUnsupported, and an agent that read it pressed again).
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return super.accessibilityPerformPress() }
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        onPress()
        return true
    }

    // MARK: Shape

    /// The fold's side: the square it sits in, on the row's top-right corner.
    static var side: CGFloat { SidebarStyle.dogEarSide }

    /// `point` (this view's flipped coordinates) is on the fold: inside the triangle whose legs are
    /// the square's top and right edges.
    func foldContains(_ point: NSPoint) -> Bool {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0, point.x >= 0, point.x <= w, point.y >= 0, point.y <= h else { return false }
        return (w - point.x) / w + point.y / h <= 1
    }

    /// The fold in `rect` (flipped): from the top edge's start, along the top to the row's rounded
    /// corner, down the right edge, and back along the crease.
    static func foldPath(in rect: NSRect, cornerRadius: CGFloat) -> NSBezierPath {
        let r = max(0, min(cornerRadius, rect.width / 2, rect.height / 2))
        // A circular quarter as a cubic, close to the row layer's continuous corner at this size.
        let k: CGFloat = 0.552_284_75
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
        path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + r),
                   controlPoint1: NSPoint(x: rect.maxX - r + k * r, y: rect.minY),
                   controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + r - k * r))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }

    /// Where the glyph draws: toward the corner, clear of the crease.
    private var glyphRect: NSRect {
        let side = min(bounds.width, bounds.height)
        let g = (side * 0.4).rounded()
        let center = NSPoint(x: bounds.maxX - side * 0.3, y: bounds.minY + side * 0.3)
        return NSRect(x: center.x - g / 2, y: center.y - g / 2, width: g, height: g)
    }

    private func renderGlyph() {
        let side = Self.side
        guard side != renderedSide else { return }
        renderedSide = side
        let image = NSImage.icon(icon, size: (side * 0.4).rounded())
        image.accessibilityDescription = label
        self.image = image
        tintedGlyph = nil
    }

    override func layout() {
        super.layout()
        renderGlyph()
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            let lit = isPointerOnFold || isPressed
            (lit ? Palette.pressedFill : Palette.hoverFill).setFill()
            Self.foldPath(in: bounds, cornerRadius: cornerRadius).fill()
            // The crease, a hairline from the top edge's start to the right edge's end.
            let crease = NSBezierPath()
            crease.move(to: NSPoint(x: bounds.minX, y: bounds.minY))
            crease.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
            crease.lineWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
            Palette.separator.setStroke()
            crease.stroke()
            guard let image else { return }
            let tint = lit ? Palette.textPrimary : Palette.textSecondary
            let glyph = tintedGlyph.flatMap { $0.color == tint ? $0.image : nil } ?? image.tinted(tint)
            tintedGlyph = (tint, glyph)
            glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func followPointer(_ event: NSEvent) {
        isPointerOnFold = foldContains(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { followPointer(event) }
    override func mouseMoved(with event: NSEvent) { followPointer(event) }
    override func mouseExited(with event: NSEvent) { isPointerOnFold = false }

    /// NSButton tracks the click inside `super.mouseDown` and returns on release.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    /// A fold hidden under the pointer gets no exit event: it shows unlit when it comes back.
    override func viewDidHide() {
        super.viewDidHide()
        isPressed = false
        isPointerOnFold = false
    }
}
