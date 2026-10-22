import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A workspace row's hover action on its top-right corner (Leo 2026-10-21: "just do it like dog
/// ears on a book on the top right"): the x, or the menu on a row that cannot close. It replaces the
/// x and the menu button that sat at the end of the title in boxes of their own.
///
/// It sits in the corner the row's fill leaves out (`SidebarCloseNotch`, Leo 2026-10-22: "a smaller
/// top right corner not higlighitng bc the button itself chopped off that top right"), so its frame
/// is that cut and it draws nothing but its glyph: no fill, no box, no fold. The glyph keeps one place
/// in every cut, toward the corner. It takes clicks in its whole frame, the part the row does not
/// highlight.
final class SidebarDogEarButton: NSButton {
    var onPress: (() -> Void)?
    /// What a press does, for VoiceOver and the themed tooltip.
    var label: String {
        didSet {
            guard label != oldValue else { return }
            setAccessibilityLabel(label)
            themedToolTip = label
            image?.accessibilityDescription = label
        }
    }
    /// The pointer is on the button: the glyph in the primary text color.
    var isPointerOn = false { didSet { if isPointerOn != oldValue { needsDisplay = true } } }
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
        // Over the row's trailing marks, which keep their places under the corner.
        layer?.zPosition = Self.zPosition
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

    /// Over the row's marks (zPosition 0); a row control that takes clicks under it draws above it.
    static let zPosition: CGFloat = 1

    /// The square the glyph is placed in, on the row's top-right corner (the old dog-ear's).
    static var side: CGFloat { SidebarStyle.dogEarSide }

    /// Where the glyph draws: its center 0.3 of `side` from the row's top and right edges, whatever
    /// the cut's size, so the x never moves between them.
    var glyphRect: NSRect {
        let g = (Self.side * 0.4).rounded()
        let center = NSPoint(x: bounds.maxX - Self.side * 0.3, y: bounds.minY + Self.side * 0.3)
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
            guard let image else { return }
            let tint = isPointerOn || isHighlighted ? Palette.textPrimary : Palette.textSecondary
            let glyph = tintedGlyph.flatMap { $0.color == tint ? $0.image : nil } ?? image.tinted(tint)
            tintedGlyph = (tint, glyph)
            glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isPointerOn = true }
    override func mouseExited(with event: NSEvent) { isPointerOn = false }

    /// A button hidden under the pointer gets no exit event: it shows unlit when it comes back.
    override func viewDidHide() {
        super.viewDidHide()
        isPointerOn = false
    }
}
