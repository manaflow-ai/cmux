import AppKit
import CmuxCanvas

/// Transparent overlay that draws snap alignment guides during a drag or
/// resize gesture. Guides are in document coordinates (same space as pane
/// view frames).
@MainActor
final class CanvasGuidesView: NSView {
    private var guides: [CanvasGuide] = []
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

    override func draw(_ dirtyRect: NSRect) {
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
