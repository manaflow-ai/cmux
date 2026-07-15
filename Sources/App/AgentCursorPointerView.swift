import AppKit

/// Draws the Sky computer-use cursor (gray kite + white outline) as a stable
/// AppKit view, matching the `sky` built-in shape from cua PR #1.
@MainActor
final class AgentCursorPointerView: NSView {
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("AgentCursorPointer")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Scale from the Sky asset's 18.59-unit viewBox to view points. The kite
    /// silhouette occupies ~11.2 units of that box, so this renders a ~17pt cursor.
    private static let skyScale: CGFloat = 1.5

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Sky cursor, replicated byte-for-byte from the `SKY_CURSOR_SVG` asset in
        // cua PR #1 (branch feat-sky-cursor-idle):
        //   libs/cua-driver/rust/crates/cursor-overlay/src/shape.rs
        // A gray (#808080) kite with a white (#FFFFFF) 1.7 outline. The SVG uses
        // `paint-order: stroke` (outline path drawn first, fill on top) so the white
        // outline sits *outside* the fill. Tip is near the origin — it points
        // up-left and never rotates, with no glow/bloom. The view is flipped
        // (y-down), matching the SVG coordinate system, so path coords map directly.
        ctx.saveGState()
        ctx.scaleBy(x: Self.skyScale, y: Self.skyScale)

        let kite = CGMutablePath()
        kite.move(to: CGPoint(x: 0.68, y: 1.83))
        kite.addLine(to: CGPoint(x: 3.63, y: 9.78))
        kite.addQuadCurve(to: CGPoint(x: 5.3, y: 9.66), control: CGPoint(x: 4.67, y: 12.59))
        kite.addLine(to: CGPoint(x: 5.44, y: 9.01))
        kite.addQuadCurve(to: CGPoint(x: 9.01, y: 5.44), control: CGPoint(x: 6.08, y: 6.08))
        kite.addLine(to: CGPoint(x: 9.66, y: 5.3))
        kite.addQuadCurve(to: CGPoint(x: 9.78, y: 3.63), control: CGPoint(x: 12.59, y: 4.67))
        kite.addLine(to: CGPoint(x: 1.83, y: 0.68))
        kite.addQuadCurve(to: CGPoint(x: 0.68, y: 1.83), control: CGPoint(x: 0, y: 0))
        kite.closeSubpath()

        // Outline first (paint-order: stroke), then the gray fill on top.
        ctx.addPath(kite)
        ctx.setLineWidth(1.7)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.strokePath()

        ctx.addPath(kite)
        ctx.setFillColor(CGColor(gray: 128.0 / 255.0, alpha: 1))
        ctx.fillPath()

        ctx.restoreGState()
    }
}
