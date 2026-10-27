public import AppKit

/// The hairline between groups of a popup's rows (Chrome's footer separator): a ``ChromeFillLayer``
/// in the theme's separator color, inset 6 pt at each end, never a `draw(_:)` backing store. The
/// page menu (``WebPopupHost``) and the page's suggestion popup use it, so popup stills show one
/// separator, and a theme change recolors a layer (cc/layers/solid_color_layer.h).
public final class PopupSeparatorView: NSView {
    /// The space left clear at each end of the line.
    public static let endInset: CGFloat = 6

    /// The line: a layer color, placed in the middle of the view.
    let line = ChromeFillLayer()

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(line)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override public var wantsUpdateLayer: Bool { true }

    /// The theme's separator color, resolved for this view's appearance.
    override public func updateLayer() {
        line.backgroundColor = performWithTheme { Palette.separator.cgColor }
        placeLine()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { placeLine() }
    }

    private func placeLine() {
        line.frame = NSRect(x: Self.endInset, y: bounds.midY.rounded(.down),
                            width: max(0, bounds.width - 2 * Self.endInset), height: 1)
    }

    // visibility-walk-allow: one invalidation; AppKit updates only views on screen, so a hidden separator pays nothing
    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true // invalidate: the appearance changed; the separator color resolves again.
    }
}
