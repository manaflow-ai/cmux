import AppKit

final class BrowserActivePaneBoundaryOverlayView: NSView {
    private let boundaryLayer = CAShapeLayer()
    private var includesTopEdge = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        boundaryLayer.fillColor = NSColor.clear.cgColor
        boundaryLayer.lineWidth = WindowBrowserSlotActivePaneBoundaryMetrics.lineWidth
        boundaryLayer.lineJoin = .miter
        layer?.addSublayer(boundaryLayer)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setBoundary(visible: Bool, color: NSColor, includesTopEdge: Bool) {
        self.includesTopEdge = includesTopEdge
        boundaryLayer.strokeColor = color.cgColor
        isHidden = !visible
        updatePath()
    }

    func setIncludesTopEdge(_ includesTopEdge: Bool) {
        guard self.includesTopEdge != includesTopEdge else { return }
        self.includesTopEdge = includesTopEdge
        updatePath()
    }

    override func layout() {
        super.layout()
        updatePath()
    }

    private func updatePath() {
        boundaryLayer.frame = bounds
        let inset = WindowBrowserSlotActivePaneBoundaryMetrics.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else {
            boundaryLayer.path = nil
            return
        }
        guard !includesTopEdge else {
            boundaryLayer.path = CGPath(rect: rect, transform: nil)
            return
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        boundaryLayer.path = path
    }
}
