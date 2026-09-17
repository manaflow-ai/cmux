import AppKit
import CmuxCanvas

/// Transparent overlay that draws snap alignment guides during a drag or
/// resize gesture. Guides are in document coordinates (same space as pane
/// view frames).
@MainActor
final class CanvasGuidesView: NSView {
    private var guides: [CanvasGuide] = []
    /// The tab-bar rect of a join target during a drag, in this view's
    /// document coordinates. `nil` clears the highlight.
    private var joinHighlight: CGRect?
    /// Converts canvas coordinates into this view's document coordinates.
    var canvasToDocumentOffset: CGPoint = .zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Replaces the rendered guides. Pass an empty array to clear.
    func setGuides(_ guides: [CanvasGuide]) {
        guard guides != self.guides else { return }
        self.guides = guides
        needsDisplay = true
    }

    /// Highlights a pane's tab-bar rect as the drop/join target during a drag.
    /// Pass `nil` to clear. The rect is in this view's document coordinates
    /// (same space as pane view frames).
    func setJoinHighlight(_ rect: CGRect?) {
        guard rect != joinHighlight else { return }
        joinHighlight = rect
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawJoinHighlight()
        drawGuides()
    }

    private func drawJoinHighlight() {
        guard let rect = joinHighlight else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawGuides() {
        guard !guides.isEmpty else { return }
        let color = NSColor.controlAccentColor.withAlphaComponent(0.8)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        for guide in guides {
            switch guide.axis {
            case .vertical:
                let x = guide.position + canvasToDocumentOffset.x
                path.move(to: CGPoint(x: x, y: guide.span.lowerBound + canvasToDocumentOffset.y))
                path.line(to: CGPoint(x: x, y: guide.span.upperBound + canvasToDocumentOffset.y))
            case .horizontal:
                let y = guide.position + canvasToDocumentOffset.y
                path.move(to: CGPoint(x: guide.span.lowerBound + canvasToDocumentOffset.x, y: y))
                path.line(to: CGPoint(x: guide.span.upperBound + canvasToDocumentOffset.x, y: y))
            }
        }
        path.stroke()
    }
}
