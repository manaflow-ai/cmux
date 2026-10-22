import AppKit

/// A thin determinate progress bar (the iOS download): a track and a fill, two layers, redrawn
/// only when ``fraction`` changes. Indeterminate waits use the shared spinner instead.
@MainActor
final class PhoneProgressBar: NSView {
    private let fill = CALayer()

    /// 0...1.
    var fraction: Double = 0 {
        didSet { if fraction != oldValue { needsLayout = true; setAccessibilityValue(Int((fraction * 100).rounded(.down))) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.addSublayer(fill)
        fill.cornerRadius = 3
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * min(max(fraction, 0), 1), height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}
