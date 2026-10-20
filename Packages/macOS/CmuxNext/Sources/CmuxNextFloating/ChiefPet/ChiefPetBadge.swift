import AppKit
import CmuxNextDesign

/// The pet's count of notices that wait for the user: a small round attention-colored badge at the
/// character's top right, as the references draw it (fd383405: a gold 1 on the mascot).
final class ChiefPetBadge: NSView {
    static let height: CGFloat = 16
    private let label = ChromeLabel(labelWithString: "")

    var count = 0 {
        didSet { label.stringValue = count > 99 ? "99+" : String(count); needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var fittingSize: NSSize {
        NSSize(width: max(Self.height, ceil(label.intrinsicContentSize.width) + 8), height: Self.height)
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recolor()
    }

    private func recolor() {
        performWithTheme {
            layer?.backgroundColor = Palette.attention.cgColor
            label.textColor = Palette.textOnPrimary
            label.font = Typography.caption
        }
    }
}
