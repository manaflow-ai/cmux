public import AppKit

/// A chrome region's tonal step (the sidebar, the tab strips): one
/// translucent theme color laid over the window's single backdrop.
///
/// The window root owns the only material and tint (``WindowMaterialView``,
/// from `WindowBackdrop(tokens)`), or paints the solid background when the
/// window is opaque. This view adds no material and no opaque fill of its
/// own, so a see-through window never blurs twice, and the same step reads
/// the same over the solid background, the frosted or glass material, and
/// with Reduce Transparency on (where the root is solid). Content
/// (terminals, pages) never sits on it.
public final class ChromeStepView: NSView {
    /// The step color, read inside this view's theme scope.
    public var step: @MainActor () -> NSColor { didSet { applyTheme() } }

    public init(step: @escaping @MainActor () -> NSColor) {
        self.step = step
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The color painted now (tests read it).
    var stepColor: CGColor? { layer?.backgroundColor }

    /// Decoration only: clicks reach the chrome above or the window.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    private func applyTheme() {
        performWithTheme { layer?.backgroundColor = step().cgColor }
    }
}
