import AppKit

@MainActor
final class WorkspaceAttentionFlashRingNativeView: NSView {
    private let shapeLayer = CAShapeLayer()
    private var ringOpacity = 0.0
    private var reason: WorkspaceAttentionFlashReason = .navigation

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(shapeLayer)
        shapeLayer.fillColor = NSColor.clear.cgColor
        shapeLayer.lineWidth = PanelOverlayRingMetrics.lineWidth
        update(opacity: 0, reason: .navigation)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        shapeLayer.frame = bounds
        shapeLayer.path = CGPath(
            roundedRect: PanelOverlayRingMetrics.pathRect(in: bounds),
            cornerWidth: PanelOverlayRingMetrics.cornerRadius,
            cornerHeight: PanelOverlayRingMetrics.cornerRadius,
            transform: nil
        )
    }

    func update(opacity: Double, reason: WorkspaceAttentionFlashReason) {
        ringOpacity = opacity
        self.reason = reason
        let presentation = WorkspaceAttentionCoordinator.flashStyle(for: reason)
        let color = presentation.accent.strokeColor
        shapeLayer.strokeColor = color.withAlphaComponent(CGFloat(opacity)).cgColor
        shapeLayer.shadowColor = color.cgColor
        shapeLayer.shadowOpacity = Float(opacity * presentation.glowOpacity)
        shapeLayer.shadowRadius = presentation.glowRadius
        shapeLayer.shadowOffset = .zero
        needsLayout = true
    }
}
