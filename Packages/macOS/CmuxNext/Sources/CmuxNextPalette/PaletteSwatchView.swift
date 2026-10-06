import AppKit
import CmuxNextDesign
import QuartzCore

/// Real colors in a palette row's icon place (R98): one color is a dot,
/// several (a theme) are side-by-side stripes in a rounded square. A
/// hairline in the separator color keeps a swatch that matches the palette
/// background visible.
final class PaletteSwatchView: NSView {
    var colors: [ThemeRGB] = [] {
        didSet { if colors != oldValue { rebuild() } }
    }

    private var stripes: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func rebuild() {
        stripes.forEach { $0.removeFromSuperlayer() }
        stripes = colors.map { color in
            let stripe = CALayer()
            stripe.backgroundColor = color.cgColor
            layer?.addSublayer(stripe)
            return stripe
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = bounds.width / CGFloat(max(1, stripes.count))
        for (index, stripe) in stripes.enumerated() {
            stripe.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
        layer?.cornerRadius = colors.count == 1 ? min(bounds.width, bounds.height) / 2 : Metrics.itemCornerRadius / 2
        applyBorder()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorder()
    }

    private func applyBorder() {
        performWithTheme {
            layer?.borderColor = Palette.separator.cgColor
            layer?.borderWidth = Metrics.lineWidth(Metrics.dividerThickness)
        }
    }
}
