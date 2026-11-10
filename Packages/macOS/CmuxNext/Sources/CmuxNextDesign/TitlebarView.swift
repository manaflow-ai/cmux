public import AppKit

/// The standard titlebar strip (`window.titlebar` "standard") above the
/// content column: the workspace title, centered, secondary text. Dragging
/// it moves the window; a double-click runs the user's titlebar action
/// (both through `TitlebarDragPolicy`).
///
/// A new title costs one draw of the label and nothing else: the label has the strip's width inside
/// the side insets and the height of one line of its font, centers and truncates its own text, has no
/// intrinsic size and no constraint. So a space or workspace switch, which sets a title each time,
/// measures no text, starts no constraint pass in the window and moves no frame.
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

    override public func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true // the line's height rounds to the backing scale
    }

    /// The label across the strip, `Metrics.space5` free at each side of its text (its alignment rect),
    /// one line of its font tall and centered in the strip's height. The line's height is the measure of
    /// an empty label (`LabelText.measure`: the font's line, no text layout), so it is the same for
    /// every title.
    override public func layout() {
        super.layout()
        let insets = label.alignmentRectInsets
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let height = LabelText.measure(NSAttributedString(), font: label.font, shape: label.shape, width: nil, scale: scale).size.height
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
/// invalidates no constraint and asks for no layout: its frame depends on the strip and the font only.
private final class TitlebarTitleLabel: ChromeLabel {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func invalidateIntrinsicContentSize() {}
}
