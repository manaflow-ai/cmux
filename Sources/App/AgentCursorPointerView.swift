import AppKit

/// Draws Lawrence's browser-agent cursor as a stable AppKit view.
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

    override func draw(_ dirtyRect: NSRect) {
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: 0.5, y: 0.5))
        pointer.line(to: NSPoint(x: 0.5, y: 22.5))
        pointer.line(to: NSPoint(x: 6.5, y: 17))
        pointer.line(to: NSPoint(x: 10, y: 27))
        pointer.line(to: NSPoint(x: 15, y: 25.2))
        pointer.line(to: NSPoint(x: 11.5, y: 15))
        pointer.line(to: NSPoint(x: 18.5, y: 15))
        pointer.close()

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        NSColor.white.setFill()
        pointer.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.85).setStroke()
        pointer.lineWidth = 1.5
        pointer.stroke()
    }
}
