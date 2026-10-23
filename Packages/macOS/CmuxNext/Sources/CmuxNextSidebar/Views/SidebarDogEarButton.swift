import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A workspace row's hover close (or Home's menu) on its top-right corner (Leo 2026-10-21, "like dog
/// ears on a book on the top right"), in the cut the row's fill leaves out (Leo 2026-10-22, "the button
/// itself chopped off that top right", `SidebarCloseNotch`). It draws only its glyph, which keeps one
/// place in every cut, and takes exactly the clicks in the drawn cut (`cutContains`).
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
    /// The pointer is on the cut: the glyph in the primary text color.
    var isPointerOn = false { didSet { if isPointerOn != oldValue { needsDisplay = true } } }
    /// The row's drawn fill in this view's coordinates (`WorkspaceRowView.layoutDogEar`); nil: none.
    var rowFill: CGPath?
    /// Where the pointer is in the window (bottom-left origin); tests stand in for the real pointer.
    var pointerInWindow: (() -> NSPoint?)?
    private let icon: IconName
    private var renderedSide: CGFloat = 0
    /// The glyph in the last tint drawn, so a redraw in the same colors makes no new image.
    private var tintedGlyph: (color: NSColor, image: NSImage)?
    private var tracking: NSTrackingArea?
    /// The current press began in the cut; only such a press can fire, on a release in the cut.
    private var pressBegan = false

    init(icon: IconName, label: String) {
        self.icon = icon
        self.label = label
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        setAccessibilityLabel(label)
        // A button to VoiceOver at any size (the snug cut is smaller than AppKit's own buttons).
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
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

    /// `point` (this view's flipped coordinates) is in the cut: inside the frame and outside the row's
    /// drawn fill, so the hit area is the cut a person sees.
    func cutContains(_ point: NSPoint) -> Bool {
        bounds.contains(point) && !(rowFill?.contains(point) ?? false)
    }

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
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func follow(windowPoint: NSPoint?) {
        isPointerOn = windowPoint.map { cutContains(convert($0, from: nil)) } ?? false
    }

    override func mouseEntered(with event: NSEvent) { follow(windowPoint: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { follow(windowPoint: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { isPointerOn = false }

    /// The press tracks the drawn cut, not the frame: NSButton's own tracking (`super.mouseDown`) fires
    /// on a release anywhere in its bounds, which reach onto the row's fill past a rounded cut. Here a
    /// release fires only in the cut after a press there, as a button cancels on a release outside it.
    /// AppKit sends the drag and the release to the view that took the press.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        pressBegan = cutContains(convert(event.locationInWindow, from: nil))
        isHighlighted = pressBegan
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressBegan else { return }
        let inCut = cutContains(convert(event.locationInWindow, from: nil))
        isPointerOn = inCut
        isHighlighted = inCut
    }

    override func mouseUp(with event: NSEvent) {
        guard pressBegan else { return }
        let fires = isEnabled && cutContains(convert(event.locationInWindow, from: nil))
        pressBegan = false
        isHighlighted = false
        if fires { pressed() }
    }

    /// A button hidden under the pointer gets no exit event: it shows unlit when it comes back.
    override func viewDidHide() {
        super.viewDidHide()
        pressBegan = false
        isHighlighted = false
        isPointerOn = false
    }

    /// Shown under a pointer that does not move, it gets no enter event: it reads the pointer itself.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        follow(windowPoint: pointerInWindow?() ?? window?.mouseLocationOutsideOfEventStream)
    }
}
