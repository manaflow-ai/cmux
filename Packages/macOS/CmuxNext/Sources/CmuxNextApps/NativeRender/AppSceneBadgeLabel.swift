import AppKit
import CmuxNextDesign

/// A count or short label on a capsule of its tone at 14% (secondary by default), in the shortcut
/// face with tabular digits: a Row's trailing `badge` and the `Badge` node.
final class AppSceneBadgeLabel: NSView {
    private let label = ChromeLabel(labelWithString: "")
    private var tone: AppJSON?

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
    func configure(text: String?, tone: AppJSON?) {
        label.stringValue = text ?? ""
        isHidden = (text ?? "").isEmpty
        self.tone = tone
        needsLayout = true
        applyColors()
    }

    /// Paints the label and capsule in the view's theme.
    func applyColors() {
        performWithTheme {
            let color = tone?.sceneColor ?? Palette.textSecondary
            label.textColor = color
            layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        }
    }

    override var fittingSize: NSSize {
        let text = label.naturalSize
        return NSSize(width: ceil(text.width) + 2 * Metrics.space2, height: max(Metrics.iconSize, ceil(text.height)))
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
