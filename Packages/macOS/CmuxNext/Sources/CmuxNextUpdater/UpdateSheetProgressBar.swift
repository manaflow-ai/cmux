import AppKit
import CmuxNextDesign

/// The update sheet's thin progress bar, drawn with layers: a measured fraction fills the track;
/// unmeasured work sweeps a short segment across it while indicator loops run (still otherwise:
/// the symbol's effect alone shows work then, and it stops too).
final class UpdateSheetProgressBar: NSView {
    /// nil is unmeasured.
    let fraction: Double?
    private let track = CALayer()
    private let bar = CALayer()
    private static let sweepKey = "update.progress.sweep"
    /// The unmeasured segment's share of the track.
    private static let sweepWidth: CGFloat = 0.32
    private static let height: CGFloat = 4

    init(fraction: Double?) {
        self.fraction = fraction
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: Self.height))
        wantsLayer = true
        track.masksToBounds = true
        track.cornerRadius = Self.height / 2
        bar.cornerRadius = Self.height / 2
        bar.anchorPoint = .zero
        track.addSublayer(bar)
        layer?.addSublayer(track)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityIdentifier("cmux.update.progress")
        if let fraction { setAccessibilityValue(NSNumber(value: fraction)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    /// Whether the unmeasured sweep runs (tests).
    var isSweeping: Bool { bar.animation(forKey: Self.sweepKey) != nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        track.frame = bounds
        performWithTheme {
            track.backgroundColor = Palette.hoverFill.cgColor
            bar.backgroundColor = Palette.textSecondary.cgColor
        }
        if let fraction {
            bar.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(min(1, max(0.03, fraction))), height: bounds.height)
            return
        }
        let segment = bounds.width * Self.sweepWidth
        bar.frame = CGRect(x: 0, y: 0, width: segment, height: bounds.height)
        bar.removeAnimation(forKey: Self.sweepKey)
        guard window != nil, let sweep = Motion.indicators.sweepAnimation(segment: segment, travel: bounds.width) else {
            bar.isHidden = true
            return
        }
        bar.isHidden = false
        bar.add(sweep, forKey: Self.sweepKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}
