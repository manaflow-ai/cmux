import AppKit
import CmuxNextDesign

/// A count or short label on a capsule of its tone at 14% (secondary by default), in the shortcut
/// face with tabular digits: a Row's trailing `badge` and the `Badge` node. The `Badge` node's
/// variant moves it: prominent is a 28% capsule in semibold, subtle is the text with no capsule.
final class AppSceneBadgeLabel: NSView {
    private let label = ChromeLabel(labelWithString: "")
    private var tone: AppJSON?
    private var variant: AppSceneComponentVariant = .standard

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = Typography.shortcut
        label.maximumNumberOfLines = 1
        addSubview(label)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    /// Shows `text` (hidden when nil or empty) in `tone`.
    func configure(text: String?, tone: AppJSON?, variant: AppSceneComponentVariant = .standard) {
        label.stringValue = text ?? ""
        isHidden = (text ?? "").isEmpty
        self.tone = tone
        self.variant = variant
        label.font = variant == .prominent ? Typography.system(size: Typography.shortcut.pointSize, weight: .semibold) : Typography.shortcut
        needsLayout = true
        applyColors()
    }

    /// Paints the label and capsule in the view's theme.
    func applyColors() {
        performWithTheme {
            let color = tone?.sceneColor ?? Palette.textSecondary
            label.textColor = color
            let alpha: CGFloat = switch variant {
            case .prominent: 0.28
            case .subtle: 0
            case .standard: 0.14
            }
            layer?.backgroundColor = color.withAlphaComponent(alpha).cgColor
        }
    }

    override var fittingSize: NSSize {
        let text = label.naturalSize
        let inset = variant == .subtle ? 0 : Metrics.space2
        return NSSize(width: ceil(text.width) + 2 * inset, height: max(Metrics.iconSize, ceil(text.height)))
    }

    override func layout() {
        super.layout()
        let text = label.naturalSize
        label.frame = CGRect(x: (bounds.width - text.width) / 2, y: (bounds.height - text.height) / 2,
                             width: ceil(text.width), height: ceil(text.height)).integral
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}
