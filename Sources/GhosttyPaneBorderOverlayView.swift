import AppKit
import QuartzCore

final class GhosttyPaneBorderOverlayView: NSView {
    private static let lineWidth: CGFloat = 2
    private static let inset: CGFloat = 1

    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        autoresizingMask = [.width, .height]
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = Self.lineWidth
        borderLayer.lineJoin = .miter
        borderLayer.lineCap = .butt
        borderLayer.opacity = 0
        layer?.addSublayer(borderLayer)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        updatePath()
    }

    func setBorder(color: NSColor?, visible: Bool) {
        let shouldShow = visible && color != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.strokeColor = color?.cgColor
        borderLayer.opacity = shouldShow ? 1 : 0
        isHidden = !shouldShow
        updatePath()
        CATransaction.commit()
    }

    private func updatePath() {
        let rect = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        borderLayer.frame = bounds
        borderLayer.path = CGPath(rect: rect, transform: nil)
    }
}
