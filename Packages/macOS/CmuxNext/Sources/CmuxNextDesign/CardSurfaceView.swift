public import AppKit

/// The surface of the sidebar's cards (Update Ready, the notices and tips): the shared neutral
/// glass (``FloatingGlassStyle/card``, user 2026-10-20 after Rex), a gray veil over the sidebar's
/// own glass with the top-lit rim, never a second glass layer on glass, and no shadow. Under
/// Reduce Transparency it is the opaque elevated fill with a hairline, as every translucent
/// surface is. (Before 2026-10-20: the composer's 13% text fill and 18% edge.)
@MainActor
public final class CardSurfaceView: NSView {
    /// The shared glass style the card draws.
    public static let style = FloatingGlassStyle.card

    private let reduceTransparency: ReduceTransparency
    /// The rim; nil under Reduce Transparency.
    public private(set) var rimView: GlassRimView?

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
        let opaque = reduceTransparency.isEnabled
        let look = Self.style.look(isDark: themeTokens.isDark)
        updateRim(opaque ? nil : look)
        performWithTheme {
            layer?.backgroundColor = (opaque ? Palette.elevatedBackground : look.veil.nsColor).cgColor
            layer?.borderColor = opaque ? Palette.separator.cgColor : nil
            layer?.borderWidth = opaque ? Metrics.lineWidth(1) : 0
        }
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
}
