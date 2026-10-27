import AppKit
import CmuxNextDesign

/// The standard titlebar strip (`window.titlebar` "standard") above the
/// content column: the workspace title, centered, secondary text. Dragging
/// it moves the window; a double-click runs the user's titlebar action
/// (both through `TitlebarDragPolicy`).
final class TitlebarView: NSView, TitlebarPressDeciding {
    private let label = ChromeLabel(labelWithString: "") // a layer color: a theme change blends it (I5)

    var title: String = "" {
        didSet {
            guard title != oldValue else { return }
            label.stringValue = title
            needsLayout = true // invalidate: another title (the guard above) is measured and centered again.
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Typography.bodyEmphasized
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The title's frame: centered in `bounds`, as wide as its text up to `inset` from each side
    /// (it truncates in the middle past that).
    static func labelFrame(in bounds: CGRect, natural: CGSize, inset: CGFloat) -> CGRect {
        let width = min(natural.width, max(0, bounds.width - 2 * inset))
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - natural.height / 2, width: width, height: natural.height)
    }

    override func layout() {
        super.layout()
        let frame = backingAlignedRect(Self.labelFrame(in: bounds, natural: label.naturalSize, inset: Metrics.space5),
                                       options: .alignAllEdgesNearest)
        if label.frame != frame { label.frame = frame }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { label.textColor = Palette.textSecondary }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
    }

    func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .movesWindow }
}
