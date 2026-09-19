import AppKit
import CmuxFoundation

/// One chevron rotated in a fixed native disclosure hit target. AppKit still
/// owns state, target/action, keyboard navigation and outline accessibility.
final class CloudTreeDisclosureButton: NSButton {
    init(nativeButton: NSButton) {
        super.init(frame: nativeButton.frame)
        identifier = nativeButton.identifier
        setButtonType(.onOff)
        isBordered = false
        title = ""
        target = nativeButton.target
        action = nativeButton.action
        state = nativeButton.state
        focusRingType = .none
        setAccessibilityRole(.disclosureTriangle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let scale = GlobalFontMagnification.scaledSize(1)
        // Use a square chevron footprint. A tall, narrow path rotated for the
        // expanded state changes its apparent size; a square path keeps the
        // collapsed and expanded glyphs pixel-consistent.
        let side = 5 * scale
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -side / 2, y: -side / 2))
        path.line(to: NSPoint(x: side / 2, y: 0))
        path.line(to: NSPoint(x: -side / 2, y: side / 2))
        let transform = AffineTransform(
            translationByX: bounds.midX,
            byY: bounds.midY
        )
        var rotation = AffineTransform()
        if state == .on { rotation.rotate(byDegrees: isFlipped ? 90 : -90) }
        path.transform(using: rotation)
        path.transform(using: transform)
        path.lineWidth = 1.25 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (isHighlighted ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
        path.stroke()
    }
}
