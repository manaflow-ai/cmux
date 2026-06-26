import AppKit
import CmuxCanvas

/// Small viewport map shown above the canvas, drawing pane positions and
/// letting pointer clicks or drags recenter the viewport.
@MainActor
final class CanvasMinimapView: NSView {
    var snapshot = CanvasMinimapSnapshot(panes: [], visibleRect: .zero, focusedPaneID: nil) {
        didSet {
            guard snapshot != oldValue else { return }
            needsDisplay = true
        }
    }

    var onCenterChanged: ((CGPoint) -> Void)?
    var onCenterSettled: ((CGPoint) -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?
    var onInteractionBegan: (() -> Void)?
    var onInteractionEnded: (() -> Void)?
    var accessibilityLabelText = "" {
        didSet { setAccessibilityLabel(accessibilityLabelText) }
    }
    var accessibilityHelpText = "" {
        didSet { setAccessibilityHelp(accessibilityHelpText) }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isDragging = false
    private var isInteractionActive = false

    private var drawingRect: CGRect {
        bounds.insetBy(dx: 10, dy: 10)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        self.trackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        beginInteraction()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        endInteractionIfIdle()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isPointerInside = bounds.contains(point)
        isDragging = true
        beginInteraction()
        recenter(at: point, settled: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isPointerInside = bounds.contains(point)
        recenter(at: point, settled: false)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isPointerInside = bounds.contains(point)
        isDragging = false
        recenter(at: point, settled: true)
        endInteractionIfIdle()
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?(event)
    }

    func resetInteractionState() {
        isPointerInside = false
        isDragging = false
        isInteractionActive = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard snapshot.shouldShow else { return }
        drawBackground()
        drawPanes()
        drawViewport()
    }

    private func recenter(at point: CGPoint, settled: Bool) {
        let projectedBounds = snapshot.projectedNavigationBounds(in: drawingRect)
        let clamped = CGPoint(
            x: min(max(point.x, projectedBounds.minX), projectedBounds.maxX),
            y: min(max(point.y, projectedBounds.minY), projectedBounds.maxY)
        )
        let center = snapshot.canvasPoint(for: clamped, in: drawingRect)
        if settled {
            onCenterSettled?(center)
        } else {
            onCenterChanged?(center)
        }
    }

    private func beginInteraction() {
        guard !isInteractionActive else { return }
        isInteractionActive = true
        onInteractionBegan?()
    }

    private func endInteractionIfIdle() {
        guard !isPointerInside, !isDragging else { return }
        endInteraction()
    }

    private func endInteraction() {
        guard isInteractionActive else { return }
        isInteractionActive = false
        onInteractionEnded?()
    }

    private func drawBackground() {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.withAlphaComponent(0.72).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawPanes() {
        for pane in snapshot.panes {
            let rect = displayRect(snapshot.minimapRect(for: pane.frame, in: drawingRect))
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            if pane.id == snapshot.focusedPaneID {
                NSColor.controlAccentColor.withAlphaComponent(0.36).setFill()
                path.fill()
                NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                NSColor.labelColor.withAlphaComponent(0.20).setFill()
                path.fill()
                NSColor.labelColor.withAlphaComponent(0.28).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func drawViewport() {
        let rect = displayRect(snapshot.minimapRect(for: snapshot.visibleRect, in: drawingRect))
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func displayRect(_ rect: CGRect) -> CGRect {
        let minSize: CGFloat = 3
        var rect = rect
        if rect.width < minSize {
            rect.origin.x -= (minSize - rect.width) / 2
            rect.size.width = minSize
        }
        if rect.height < minSize {
            rect.origin.y -= (minSize - rect.height) / 2
            rect.size.height = minSize
        }
        return rect.integral
    }
}
