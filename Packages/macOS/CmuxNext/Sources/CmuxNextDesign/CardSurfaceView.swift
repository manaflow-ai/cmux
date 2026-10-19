public import AppKit

/// The surface of the sidebar's cards (Update Ready, the notices and tips; Leo 2026-10-13): the
/// agent composer's (`--acpmux-composer-bg` and `--acpmux-composer-edge` in
/// webviews/src/agent-session/acpmux/styles.css), so a card beside the composer reads as the same
/// app. The theme's text at 13% over whatever is behind, the wallpaper on a wallpaper theme, with
/// a 0.5 pt edge of the text at 18% and no shadow. The web's "Updated to" card draws the same
/// (`.wn-card`, webviews/src/pages/changelog/updateSurfaces.css). Under Reduce Transparency it is
/// the opaque elevated fill with a hairline, as every translucent surface is.
@MainActor
public final class CardSurfaceView: NSView {
    /// The fill's share of the text color (the composer's 13%).
    public static let fillShare: CGFloat = 0.13
    /// The edge's share of the text color (the composer's 18%).
    public static let edgeShare: CGFloat = 0.18

    private let reduceTransparency: ReduceTransparency

    public init(cornerRadius: CGFloat = Metrics.space3, reduceTransparency: ReduceTransparency = .shared) {
        self.reduceTransparency = reduceTransparency
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        setAccessibilityElement(false)
        reduceTransparency.register(self)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    public var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { layer?.cornerRadius = newValue }
    }

    nonisolated public override var wantsUpdateLayer: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func updateLayer() {
        performWithTheme {
            let opaque = reduceTransparency.isEnabled
            layer?.backgroundColor = (opaque ? Palette.elevatedBackground
                : Palette.textPrimary.withAlphaComponent(Self.fillShare)).cgColor
            layer?.borderColor = (opaque ? Palette.separator
                : Palette.textPrimary.withAlphaComponent(Self.edgeShare)).cgColor
            layer?.borderWidth = Metrics.lineWidth(opaque ? 1 : 0.5)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
}
