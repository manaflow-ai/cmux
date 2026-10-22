public import AppKit

/// The surface of the sidebar's cards (Update Ready, the notices and tips): the shared neutral
/// glass (``FloatingGlassStyle/card``, user 2026-10-20 after Rex), a gray veil over the sidebar's
/// own glass with the top-lit rim (and, in light mode, a hairline on every side,
/// ``lightEdgeShare``), never a second glass layer on glass, and no shadow. Under
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

    /// The light-mode hairline's share of the text color, on all four sides. In light mode the
    /// card's rim (``FloatingGlassStyle/card``'s light rim) fades to white at the top, so over the
    /// white sidebar the card had no top edge (live-qa, nightly 3a63d6d: sides about 208 gray, top
    /// about 254, the sidebar's own). 17228e100b1 dropped the old all-sides edge (the text at 18%,
    /// 0.5 pt); this keeps it in light mode, a little lighter. The rim itself is unchanged: toasts
    /// and dialogs share that look.
    public static let lightEdgeShare: CGFloat = 0.14

    public override func updateLayer() {
        let opaque = reduceTransparency.isEnabled
        let isDark = themeTokens.isDark
        let look = Self.style.look(isDark: isDark)
        updateRim(opaque ? nil : look)
        performWithTheme {
            layer?.backgroundColor = (opaque ? Palette.elevatedBackground : look.veil.nsColor).cgColor
            if opaque {
                layer?.borderColor = Palette.separator.cgColor
                layer?.borderWidth = Metrics.lineWidth(1)
            } else if !isDark {
                layer?.borderColor = Palette.textPrimary.withAlphaComponent(Self.lightEdgeShare).cgColor
                layer?.borderWidth = Metrics.lineWidth(0.5)
            } else {
                layer?.borderColor = nil
                layer?.borderWidth = 0
            }
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
