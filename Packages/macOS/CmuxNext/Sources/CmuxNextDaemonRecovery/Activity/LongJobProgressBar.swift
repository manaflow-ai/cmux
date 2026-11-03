import AppKit
import CmuxNextDesign

/// A long job's determinate progress: a thin track and its filled part, drawn with no animation
/// (each progress step moves the fill in one frame; the job's own progress is the motion). Shown
/// only for a job whose size is known; an unknown size shows no bar, never a spinner.
final class LongJobProgressBar: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    /// 0...1.
    private(set) var fraction: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        track.cornerRadius = 2
        fill.cornerRadius = 2
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }

    func set(fraction: Double) {
        let clamped = min(1, max(0, fraction))
        guard clamped != self.fraction else { return }
        self.fraction = clamped
        setAccessibilityValue(clamped)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.frame = CGRect(x: 0, y: 0, width: (bounds.width * fraction).rounded(), height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        // No implicit fade on a theme change (motion gate: changes apply in one frame).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        performWithTheme {
            track.backgroundColor = Palette.separator.cgColor
            fill.backgroundColor = Palette.textSecondary.cgColor
        }
        CATransaction.commit()
    }
}
