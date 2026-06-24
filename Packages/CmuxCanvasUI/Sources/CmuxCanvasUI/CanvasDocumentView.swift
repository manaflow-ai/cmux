import AppKit

/// The scrollable document of the canvas: a flipped view whose subviews are
/// `CanvasPaneView`s plus the guides overlay. Draws a subtle dot grid so the
/// user keeps a sense of position while panning empty space.
@MainActor
final class CanvasDocumentView: NSView {
    /// Spacing of the orientation dot grid, in canvas points.
    private static let gridSpacing: CGFloat = 32
    private static let gridDotRadius: CGFloat = 1

    /// Offset from canvas coordinates to document coordinates. Updated by the
    /// root view whenever the document is re-sized around the content.
    var canvasToDocumentOffset: CGPoint = .zero {
        didSet {
            guard canvasToDocumentOffset != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Canvas fill, resolved by the host through ``CanvasTheme``.
    var canvasBackground: NSColor = .windowBackgroundColor {
        didSet {
            guard canvasBackground != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        canvasBackground.setFill()
        dirtyRect.fill()

        // Dots are aligned to canvas space so they stay put when the document
        // re-centers around content.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let spacing = Self.gridSpacing
        let radius = Self.gridDotRadius
        context.setFillColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.18).cgColor)
        let phaseX = canvasToDocumentOffset.x.truncatingRemainder(dividingBy: spacing)
        let phaseY = canvasToDocumentOffset.y.truncatingRemainder(dividingBy: spacing)
        var x = (dirtyRect.minX - phaseX).rounded(.down) - (dirtyRect.minX - phaseX)
            .truncatingRemainder(dividingBy: spacing) + phaseX
        while x < dirtyRect.minX { x += spacing }
        while x <= dirtyRect.maxX {
            var y = (dirtyRect.minY - phaseY).rounded(.down) - (dirtyRect.minY - phaseY)
                .truncatingRemainder(dividingBy: spacing) + phaseY
            while y < dirtyRect.minY { y += spacing }
            while y <= dirtyRect.maxY {
                let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fillEllipse(in: dot)
                y += spacing
            }
            x += spacing
        }
    }
}
