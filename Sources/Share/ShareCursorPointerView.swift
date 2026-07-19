import AppKit

/// A guest cursor: a vector kite silhouette in the participant's color with a
/// white outline, plus a small name chip below-right of the tip. The view is
/// flipped so the pointer tip sits at the view origin; it never intercepts
/// mouse events.
final class ShareCursorPointerView: NSView {
    private static let pointerSize: CGFloat = 20
    private static let unitViewBox: CGFloat = 13
    private static let chipFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static let chipPadding = NSSize(width: 5, height: 2)

    private let color: NSColor
    private var name: String

    init(color: NSColor, name: String) {
        self.color = color
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        sizeToFitContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// The overlay is presentation-only; let events fall through to the pane.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setName(_ newName: String) {
        guard newName != name else { return }
        name = newName
        sizeToFitContent()
        needsDisplay = true
    }

    private var chipTextSize: NSSize {
        (name as NSString).size(withAttributes: [.font: Self.chipFont])
    }

    private func sizeToFitContent() {
        let text = chipTextSize
        let chipWidth = ceil(text.width) + Self.chipPadding.width * 2
        let chipHeight = ceil(text.height) + Self.chipPadding.height * 2
        setFrameSize(NSSize(
            width: max(Self.pointerSize, Self.pointerSize * 0.7 + chipWidth),
            height: Self.pointerSize * 0.9 + chipHeight
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = Self.pointerSize / Self.unitViewBox
        let path = Self.kitePath()
        var transform = AffineTransform.identity
        transform.scale(scale)
        path.transform(using: transform)

        NSColor.white.setStroke()
        path.lineWidth = 1.7
        path.lineJoinStyle = .round
        path.stroke()
        color.setFill()
        path.fill()

        drawNameChip()
    }

    private func drawNameChip() {
        let text = chipTextSize
        let chipRect = NSRect(
            x: Self.pointerSize * 0.7,
            y: Self.pointerSize * 0.9 - Self.chipPadding.height,
            width: ceil(text.width) + Self.chipPadding.width * 2,
            height: ceil(text.height) + Self.chipPadding.height * 2
        )
        let chip = NSBezierPath(roundedRect: chipRect, xRadius: 4, yRadius: 4)
        color.setFill()
        chip.fill()
        (name as NSString).draw(
            at: NSPoint(
                x: chipRect.minX + Self.chipPadding.width,
                y: chipRect.minY + Self.chipPadding.height
            ),
            withAttributes: [.font: Self.chipFont, .foregroundColor: NSColor.white]
        )
    }

    /// The kite silhouette in a ~13-unit view box, tip at the origin.
    private static func kitePath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0.68, y: 1.83))
        path.line(to: NSPoint(x: 3.63, y: 9.78))
        path.quadCurve(to: NSPoint(x: 5.3, y: 9.66), control: NSPoint(x: 4.67, y: 12.59))
        path.line(to: NSPoint(x: 5.44, y: 9.01))
        path.quadCurve(to: NSPoint(x: 9.01, y: 5.44), control: NSPoint(x: 6.08, y: 6.08))
        path.line(to: NSPoint(x: 9.66, y: 5.3))
        path.quadCurve(to: NSPoint(x: 9.78, y: 3.63), control: NSPoint(x: 12.59, y: 4.67))
        path.line(to: NSPoint(x: 1.83, y: 0.68))
        path.quadCurve(to: NSPoint(x: 0.68, y: 1.83), control: NSPoint(x: 0, y: 0))
        path.close()
        return path
    }
}

private extension NSBezierPath {
    /// Quadratic Bezier segment expressed as the equivalent cubic.
    func quadCurve(to endPoint: NSPoint, control: NSPoint) {
        let start = currentPoint
        let control1 = NSPoint(
            x: start.x + (control.x - start.x) * 2 / 3,
            y: start.y + (control.y - start.y) * 2 / 3
        )
        let control2 = NSPoint(
            x: endPoint.x + (control.x - endPoint.x) * 2 / 3,
            y: endPoint.y + (control.y - endPoint.y) * 2 / 3
        )
        curve(to: endPoint, controlPoint1: control1, controlPoint2: control2)
    }
}
