public import AppKit

/// The standard titlebar strip (`window.titlebar` "standard") above the
/// content column: the workspace title, centered, secondary text. Dragging
/// it moves the window; a double-click runs the user's titlebar action
/// (both through `TitlebarDragPolicy`).
///
/// The strip places its label itself: the label has no intrinsic size and no constraint, so a new title
/// (each space or workspace switch sets one) starts no constraint pass in the window. A shown strip
/// lays itself out once for it (the text's own size, centered); a hidden one (`window.titlebar`
/// "minimal", the default) keeps the string only and lays out when it shows.
public final class TitlebarView: NSView, TitlebarPressDeciding {
    private let label = TitlebarTitleLabel(labelWithString: "") // a layer color: a theme change blends it (I5)

    public var title: String = "" {
        didSet {
            guard title != oldValue else { return }
            label.stringValue = title
            if !isHiddenOrHasHiddenAncestor { needsLayout = true }
        }
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Typography.bodyEmphasized
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
        needsLayout = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true // a title set while hidden
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true // the text's size rounds to the backing scale
    }

    /// The title at its own size, centered; one wider than the strip keeps `Metrics.space5` free at each
    /// side of its text (the label's alignment rect) and truncates in the middle.
    override public func layout() {
        super.layout()
        let insets = label.alignmentRectInsets, natural = label.naturalSize
        let width = min(natural.width, max(bounds.width - Metrics.space5 * 2 + insets.left + insets.right, 0))
        let placed = backingAlignedRect(NSRect(x: bounds.midX - width / 2, y: bounds.midY - natural.height / 2, width: width, height: natural.height),
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
        needsLayout = true
    }

    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .movesWindow }
}

/// The titlebar's label, sized and placed by `TitlebarView.layout()`. It has no intrinsic size, so new
/// text invalidates no constraint.
private final class TitlebarTitleLabel: ChromeLabel {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func invalidateIntrinsicContentSize() {}
}
