import AppKit
import CmuxNextDesign

/// One key drawn as a small rounded cap, the palette's shortcut look: the
/// key that does the action beside it, so it can be pressed instead of
/// clicked.
final class OnboardingKeycap: NSView {
    private let key: String

    init(_ key: String) {
        self.key = key
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static var size: CGFloat { Metrics.iconSize + Metrics.space2 }

    /// theme-scoped: read inside `performWithTheme` (draw) or for measuring.
    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Typography.shortcut, .foregroundColor: Palette.textSecondary]
    }

    override var intrinsicContentSize: NSSize {
        let text = (key as NSString).size(withAttributes: attributes).width
        return NSSize(width: max(Self.size, ceil(text) + Metrics.space2 * 2), height: Self.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            let radius = Metrics.itemCornerRadius - Metrics.space1
            Palette.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            let text = key as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2), withAttributes: attributes)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
