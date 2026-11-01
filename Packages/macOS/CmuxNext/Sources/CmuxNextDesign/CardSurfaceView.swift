public import AppKit

/// The surface of the sidebar's cards (Update Ready, the notices and tips): the shared neutral
/// glass (``FloatingGlassStyle/card``, user 2026-10-20 after Rex), a gray veil over the sidebar's
/// own glass with the top-lit rim (and, in light mode, a one-pixel hairline on every side,
/// ``lightEdgeShare``), never a second glass layer on glass, and no shadow. Under
/// Reduce Transparency it is the opaque elevated fill with a hairline, as every translucent
/// surface is. (Before 2026-10-20: the composer's 13% text fill and 18% edge.)
@MainActor
public final class CardSurfaceView: NSView {
    /// The shared glass style the card draws.
    public static let style = SurfaceRole.card.neutralStyle ?? FloatingGlassStyle.card

    private let reduceTransparency: ReduceTransparency
    /// The rim; nil under Reduce Transparency.
    public private(set) var rimView: GlassRimView?
    /// The light-mode hairline (``lightEdgeShare``), above the rim: the rim's white top stroke
    /// covers a layer border drawn under it. Nil in dark mode and under Reduce Transparency.
    public private(set) var edgeView: NSView?

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
        set {
            layer?.cornerRadius = newValue
            edgeView?.layer?.cornerRadius = newValue
        }
    }

    nonisolated public override var wantsUpdateLayer: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The light-mode hairline's share of the text color, one device pixel on all four sides. In
    /// light mode the card's rim (``FloatingGlassStyle/card``'s light rim) fades to white at the top,
    /// so over the white sidebar the card had no top edge (live-qa, nightly 3a63d6d: sides about 208
    /// gray, top about 254, the sidebar's own). 17228e100b1 dropped the old all-sides edge (the text
    /// at 18%, 0.5 pt); this keeps it in light mode, a little lighter, in ``edgeView`` above the rim
    /// (a layer border on the card itself sits under the rim, whose white top hid it). The rim itself
    /// is unchanged: toasts and dialogs share that look.
    public static let lightEdgeShare: CGFloat = 0.14

    public override func updateLayer() {
        let opaque = reduceTransparency.isEnabled
        let isDark = themeTokens.isDark
        let look = Self.style.look(isDark: isDark)
        updateRim(opaque ? nil : look)
        let edge = updateEdge(shown: !opaque && !isDark)
        performWithTheme {
            layer?.backgroundColor = (opaque ? Palette.elevatedBackground : look.veil.nsColor).cgColor
            layer?.borderColor = opaque ? Palette.separator.cgColor : nil
            layer?.borderWidth = opaque ? Metrics.lineWidth(1) : 0
            edge?.borderColor = Palette.textPrimary.withAlphaComponent(Self.lightEdgeShare).cgColor
            edge?.borderWidth = Metrics.lineWidth(Self.hairline(scale: window?.backingScaleFactor))
        }
    }

    /// One device pixel, as the rim's stroke: 0.5 pt on a Retina display. A 0.5 pt border on a 1x
    /// display left the straight edges blank (only the corners' curves showed).
    static func hairline(scale: CGFloat?) -> CGFloat { 1 / max(scale ?? 2, 1) }

    /// Shows or removes the light-mode hairline, kept above the rim; answers its layer.
    private func updateEdge(shown: Bool) -> CALayer? {
        guard shown else {
            edgeView?.removeFromSuperview()
            edgeView = nil
            return nil
        }
        let edge = edgeView ?? NSView(frame: bounds)
        if edgeView == nil {
            edge.wantsLayer = true
            edge.autoresizingMask = [.width, .height]
            edge.layer?.cornerCurve = .continuous
            edge.setAccessibilityElement(false)
            edgeView = edge
        }
        edge.layer?.cornerRadius = cornerRadius
        if subviews.last !== edge { addSubview(edge, positioned: .above, relativeTo: nil) }
        return edge.layer
    }

    private func updateRim(_ look: FloatingGlassLook?) {
        guard let look else {
            rimView?.removeFromSuperview()
            rimView = nil
            return
        }
        if let rimView {
            rimView.look = look
            rimView.cornerRadius = cornerRadius
            return
        }
        let rim = GlassRimView(cornerRadius: cornerRadius, look: look)
        rim.frame = bounds
        rim.autoresizingMask = [.width, .height]
        addSubview(rim)
        rimView = rim
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}
