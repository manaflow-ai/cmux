public import AppKit

/// The standard titlebar strip (`window.titlebar` "standard") above the
/// content column: the workspace title, centered, secondary text. Dragging
/// it moves the window; a double-click runs the user's titlebar action
/// (both through `TitlebarDragPolicy`).
///
/// A new title costs the label's own measure and draw: the label has the strip's width inside the side
/// insets, centers and truncates its own text, has no intrinsic size and no constraint. So a space or
/// workspace switch, which sets a title each time, starts no constraint pass in the window and moves no
/// frame.
public final class TitlebarView: NSView, TitlebarPressDeciding {
    private let label = TitlebarTitleLabel(labelWithString: "") // a layer color: a theme change blends it (I5)

    public var title: String = "" {
        didSet { label.stringValue = title }
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Typography.bodyEmphasized
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The label across the strip, `Metrics.space5` free at each side of its text (its alignment rect),
    /// as tall as its text and centered in the strip's height.
    override public func layout() {
        super.layout()
        let insets = label.alignmentRectInsets, height = label.naturalSize.height
        let width = max(bounds.width - Metrics.space5 * 2 + insets.left + insets.right, 0)
        let placed = backingAlignedRect(NSRect(x: Metrics.space5 - insets.left, y: bounds.midY - height / 2, width: width, height: height),
                                        options: .alignAllEdgesNearest)
        if label.frame != placed { label.frame = placed }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { label.textColor = Palette.textSecondary }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
    }

    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .movesWindow }
}

/// The titlebar's label, placed by `TitlebarView.layout()`. It has no intrinsic size, so new text
/// invalidates no constraint; what could change its height (text, font, backing scale) asks the
/// titlebar for one layout of its own, which moves the label only when its height changed.
private final class TitlebarTitleLabel: ChromeLabel {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func invalidateIntrinsicContentSize() { superview?.needsLayout = true }
}
