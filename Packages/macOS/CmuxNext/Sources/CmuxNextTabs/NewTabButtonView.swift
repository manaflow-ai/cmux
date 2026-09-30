import AppKit
import CmuxNextDesign
import QuartzCore

/// The "+" after the last tab. Mouse handling lives in the strip.
final class NewTabButtonView: NSView {
    var isHovered = false { didSet { if oldValue != isHovered { updateColors(animated: true) } } }
    var isPressed = false { didSet { if oldValue != isPressed { updateColors(animated: false) } } }
    var onPress: (() -> Void)?

    private let fillLayer = CALayer()
    private let glyphLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        fillLayer.cornerRadius = Metrics.itemCornerRadius
        fillLayer.cornerCurve = .continuous
        fillLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        glyphLayer.fillColor = nil
        glyphLayer.lineWidth = Metrics.space1 * 0.7
        glyphLayer.lineCap = .round
        glyphLayer.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(glyphLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Strings.axNewTab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let square = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        fillLayer.frame = square
        glyphLayer.frame = bounds
        let arm = Metrics.space2 + Metrics.space1 / 2
        let scale = window?.backingScaleFactor ?? 2
        glyphLayer.contentsScale = scale
        let center = CGPoint(x: (square.midX * scale).rounded() / scale, y: (square.midY * scale).rounded() / scale)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - arm, y: center.y))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        glyphLayer.path = path
        CATransaction.commit()
    }

    override func updateLayer() {
        updateColors(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors(animated: false)
    }

    private func updateColors(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.14 : 0)
        CATransaction.setDisableActions(!animated)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fillLayer.backgroundColor = isPressed ? Palette.selectionFill.cgColor : (isHovered ? Palette.hoverFill.cgColor : nil)
            glyphLayer.strokeColor = (isHovered ? Palette.textPrimary : Palette.textSecondary).cgColor
        }
        CATransaction.commit()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// Flipped container with no event handling of its own.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
