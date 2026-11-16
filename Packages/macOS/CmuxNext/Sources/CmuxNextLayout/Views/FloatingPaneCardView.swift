import AppKit
import CmuxNextDesign
import QuartzCore

/// The card under a floating pane: an opaque ground with a rim and a shadow, a bar above the pane that a pointer
/// moves the pane by, and the rim on the other three sides that a pointer resizes it by. The pane's host is a
/// sibling above the card, so the card takes only the presses on its bar and its rim.
final class FloatingPaneCardView: NSView {
    /// The part of the card under the pointer: what a drag from there changes.
    enum Zone { case move, left, right, bottom, bottomLeft, bottomRight }
    enum Phase { case began(Zone), moved, ended }

    let pane: PaneID
    /// A press on the card, its drag and its release.
    var onDrag: ((Phase, NSEvent) -> Void)?
    private let grip = CALayer()
    private let cornerRadius: CGFloat
    /// The length along the bottom rim, from each corner, that resizes both ways.
    private static let cornerLength: CGFloat = 14

    init(pane: PaneID, cornerRadius: CGFloat) {
        self.pane = pane
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(grip)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = Palette.pageBackground.cgColor
            layer?.borderColor = Palette.paneBorder.cgColor
            grip.backgroundColor = Palette.paneBorder.cgColor
        }
        layer?.borderWidth = 1
        layer?.cornerRadius = cornerRadius + LayoutFloatingPane.rimWidth
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 4, width = min(36, max(0, bounds.width - 24))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grip.frame = CGRect(x: (bounds.width - width) / 2, y: (LayoutFloatingPane.barHeight - height) / 2, width: width, height: height)
        grip.cornerRadius = height / 2
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    /// The zone at `point` (the card's coordinates).
    func zone(at point: CGPoint) -> Zone {
        let rim = LayoutFloatingPane.rimWidth + 2
        let low = point.y >= bounds.maxY - rim
        if low, point.x <= bounds.minX + Self.cornerLength { return .bottomLeft }
        if low, point.x >= bounds.maxX - Self.cornerLength { return .bottomRight }
        if low { return .bottom }
        if point.y <= bounds.minY + LayoutFloatingPane.barHeight { return .move }
        if point.x <= bounds.minX + rim { return point.y >= bounds.maxY - Self.cornerLength ? .bottomLeft : .left }
        if point.x >= bounds.maxX - rim { return point.y >= bounds.maxY - Self.cornerLength ? .bottomRight : .right }
        return .move
    }

    override func resetCursorRects() {
        let rim = LayoutFloatingPane.rimWidth, bar = LayoutFloatingPane.barHeight, corner = Self.cornerLength
        addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: bar), cursor: .openHand)
        let sideHeight = max(0, bounds.height - bar - corner)
        addCursorRect(CGRect(x: 0, y: bar, width: rim, height: sideHeight), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: bounds.maxX - rim, y: bar, width: rim, height: sideHeight), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: corner, y: bounds.maxY - rim, width: max(0, bounds.width - corner * 2), height: rim), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: 0, y: bounds.maxY - corner, width: corner, height: corner), cursor: .crosshair)
        addCursorRect(CGRect(x: bounds.maxX - corner, y: bounds.maxY - corner, width: corner, height: corner), cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(.began(zone(at: convert(event.locationInWindow, from: nil))), event)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(.moved, event)
    }

    override func mouseUp(with event: NSEvent) {
        onDrag?(.ended, event)
    }
}
