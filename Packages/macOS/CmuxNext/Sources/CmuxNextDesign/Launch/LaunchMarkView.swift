public import AppKit
import QuartzCore

/// The cmux chevron on the window glass while a launch has nothing to show
/// yet. Drawn with layers from `CGPath.launchMark(in:)`, so it needs no asset,
/// webview or daemon. It stays invisible until `reveal`, so a launch whose
/// content arrives first never shows it, and fades out on `conceal`.
public final class LaunchMarkView: NSView {
    /// The mark's height; the width follows the chevron's aspect.
    public static let height: CGFloat = 36

    /// The chevron's container: opacity, scale and glow animate here.
    let mark = CALayer()
    /// The chevron's edge (`trace` draws it in).
    let outline = CAShapeLayer()
    /// The chevron's fill.
    let body = CAShapeLayer()
    /// The style the mark last resolved with (nil until `reveal`).
    public private(set) var revealedStyle: LaunchMarkStyle?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        mark.opacity = 0
        mark.shadowOffset = .zero
        mark.shadowRadius = Metrics.space3
        mark.shadowOpacity = 0
        mark.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "transform": NSNull()]
        outline.fillColor = nil
        outline.lineJoin = .round
        // Siblings: the outline draws above the body while the body is
        // still clear (`trace`).
        mark.addSublayer(body)
        mark.addSublayer(outline)
        layer?.addSublayer(mark)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(Self.height * CGPath.launchMarkAspect), height: Self.height)
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func layout() {
        super.layout()
        Motion.transaction(nil) {
            mark.frame = bounds
            body.frame = mark.bounds
            outline.frame = mark.bounds
            let path = CGPath.launchMark(in: bounds.insetBy(dx: Metrics.lineWidth(1.5), dy: Metrics.lineWidth(1.5)))
            body.path = path
            outline.path = path
            mark.shadowPath = path
        }
    }

    public override func updateLayer() {
        performWithTheme {
            Motion.transaction(nil) {
                body.fillColor = Palette.textSecondary.cgColor
                outline.strokeColor = Palette.textSecondary.cgColor
                outline.lineWidth = Metrics.lineWidth(1.5)
                mark.shadowColor = Palette.textPrimary.cgColor
            }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Resolves the mark in with `style` (`Motion.revealLaunchMark`).
    public func reveal(_ style: LaunchMarkStyle = LaunchMarkStyle.tunable.value) {
        layoutSubtreeIfNeeded()
        revealedStyle = style
        Motion.revealLaunchMark(style, mark: mark, outline: outline, body: body)
    }

    /// Fades the mark out.
    public func conceal() {
        revealedStyle = nil
        Motion.concealLaunchMark(mark)
    }

    /// Whether the mark shows (its model opacity).
    public var isRevealed: Bool { mark.opacity > 0 }
}
