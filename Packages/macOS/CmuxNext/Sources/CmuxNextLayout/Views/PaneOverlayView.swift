import AppKit
import CmuxNextDesign
import QuartzCore

/// Non-interactive pane overlay, framed on the pane's cell: the subtle
/// hairline border, the focus ring or glow (`focusRing.*`, theme gray by
/// default, never blue) and the attention ring of an unread notification
/// (`notifications.attention.*`) on the rounded content area below the
/// header (tab strip, browser toolbar), and the inactive dim over the whole
/// padded pane, rounded only where the content area is. It lives in the
/// layout's `OverlayPlane`, above content child windows, and only strokes
/// inside the content area: it never changes a pane frame or inset. A ring
/// hides the border while it shows.
final class PaneOverlayView: NSView {
    /// The pane border: shown, width in points (nil = one device pixel) and
    /// color (nil = the theme's `Palette.paneBorder`), from
    /// `layout.paneBorder`, `layout.paneBorderWidth`, `layout.paneBorderColor`.
    struct Border: Equatable {
        var shows: Bool
        var width: CGFloat?
        var color: ThemeRGB?
    }

    private let border = CALayer()
    private let ring = CALayer()
    private let glowClip = CALayer()
    private let glow = CALayer()
    private let attention = CALayer()
    private let dimLayer = CALayer()
    private var padding: CGFloat = 0
    private var cornerRadius: CGFloat = 0
    private var headerHeight: CGFloat = 0
    private var focusRing = FocusRingSettings()
    private var ringAlphaOverride: CGFloat?
    private var attentionSettings = AttentionSettings()
    private var attentionMark: AttentionMark?
    private var borderStyle = Border(shows: false)
    private var excluded: [CGRect] = []
    private var excludedBounds: CGRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glowClip.masksToBounds = true
        glowClip.addSublayer(glow)
        glow.shadowOffset = .zero
        glow.shadowOpacity = 1
        for sublayer in [dimLayer, border, ring, glowClip, attention] {
            sublayer.opacity = 0
            layer?.addSublayer(sublayer)
        }
        glow.opacity = 1
        ring.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether the focus ring or glow is showing (for `debug.layers`).
    var showsRing: Bool { ring.opacity > 0 || glowClip.opacity > 0 }
    /// Whether the hairline border is showing (for `debug.layers`).
    var showsBorder: Bool { border.opacity > 0 }
    /// Whether the attention ring is showing (for `debug.layers`).
    var showsAttention: Bool { attentionMark != nil && attention.opacity > 0 }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// The layers follow the frame in the same call. The root sets this
    /// view's frame from the layout pass (or animation frame) that places
    /// the pane, and the plane may live in another window (the overlay above
    /// Chromium pages) whose own layout pass runs later or, during a live
    /// resize, not at all: a deferred `needsLayout` left the ring at its old
    /// size for at least one frame of every resize.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { layoutLayers() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func setShape(padding: CGFloat, cornerRadius: CGFloat, headerHeight: CGFloat) {
        guard padding != self.padding || cornerRadius != self.cornerRadius || headerHeight != self.headerHeight else { return }
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.headerHeight = headerHeight
        layoutLayers()
    }

    /// The rect the border and ring trace (for tests and `debug.layers`).
    var borderFrame: CGRect { border.frame }
    /// The rect the focus ring and glow trace, in this view's coordinates
    /// (for tests and `debug.layers`).
    var ringFrame: CGRect { ring.frame }
    /// The color the focus ring strokes with (for tests).
    var ringColor: CGColor? { ring.borderColor }
    /// The inactive dim's opacity (for tests).
    var dimOpacity: Float { dimLayer.opacity }
    /// The border's line width in points and color override (for tests).
    var borderWidth: CGFloat { border.borderWidth }
    var borderColor: ThemeRGB? { borderStyle.color }

    private func layoutLayers() {
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = cornerRadius
        let padded = PaneChromeGeometry.contentRect(forCell: bounds, style: style)
        let rect = PaneChromeGeometry.roundedRect(inPadded: padded, headerHeight: headerHeight)
        let radius = PaneChromeGeometry.cornerRadius(for: rect, style: style)
        let ringRadius = focusRing.cornerRadius.map { min($0, min(rect.width, rect.height) / 2) } ?? radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [border, attention] {
            sublayer.frame = rect
            sublayer.cornerRadius = radius
        }
        for sublayer in [ring, glowClip] {
            sublayer.frame = rect
            sublayer.cornerRadius = ringRadius
        }
        dimLayer.frame = padded
        dimLayer.cornerRadius = radius
        // With a header, only the content area's (bottom) corners round.
        // The view is flipped, so its layers are too: maxY is the bottom.
        dimLayer.maskedCorners = headerHeight > 0
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        glow.frame = glowClip.bounds
        glow.cornerRadius = ringRadius
        border.borderWidth = borderStyle.width ?? PaneChromeGeometry.hairlineWidth(scale: scale)
        ring.borderWidth = focusRing.width
        glow.borderWidth = focusRing.width
        glow.shadowRadius = max(2, focusRing.width * LayoutTunables.focusGlowRadiusFactor.value)
        attention.borderWidth = attentionSettings.width
        CATransaction.commit()
    }

    /// `showsRing`: this pane is focused and the ring should mark it.
    /// `attention`: the pane's unread mark, nil when none.
    /// Hides the overlay inside `rects` (its own coordinates): a docked
    /// column covering this strip pane. Empty removes the mask.
    func setExcluded(_ rects: [CGRect]) {
        let rects = rects.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width > 0.5 && $0.height > 0.5 }
        guard rects != excluded || (!rects.isEmpty && bounds != excludedBounds) else { return }
        excluded = rects
        excludedBounds = bounds
        guard let layer else { return }
        guard !rects.isEmpty else {
            layer.mask = nil
            return
        }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(bounds)
        for rect in rects { path.addRect(rect) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.fillRule = .evenOdd
        mask.frame = bounds
        mask.path = path
        CATransaction.commit()
        if layer.mask !== mask { layer.mask = mask }
    }

    func update(showsRing: Bool, dim: CGFloat, focusRing: FocusRingSettings, ringAlphaOverride: CGFloat? = nil, border borderStyle: Border,
                attention mark: AttentionMark?, attentionSettings: AttentionSettings, animated: Bool) {
        let shapeChanged = focusRing != self.focusRing || attentionSettings != self.attentionSettings
            || borderStyle.width != self.borderStyle.width
        let showsBorder = borderStyle.shows
        self.borderStyle = borderStyle
        self.focusRing = focusRing
        self.ringAlphaOverride = ringAlphaOverride
        self.attentionSettings = attentionSettings
        if shapeChanged { layoutLayers() }
        let style = showsRing ? focusRing.effectiveStyle : .none
        let marksAttention = mark != nil && attentionSettings.style != .none
        Motion.transaction(animated ? .focus : nil) {
            ring.opacity = style == .ring ? 1 : 0
            glowClip.opacity = style == .glow ? 1 : 0
            border.opacity = showsBorder && style == .none && !marksAttention ? 1 : 0
            dimLayer.opacity = Float(dim)
        }
        applyAttention(mark, animated: animated)
        applyColors()
    }

    private func applyAttention(_ mark: AttentionMark?, animated: Bool) {
        let previous = attentionMark
        attentionMark = mark
        guard let mark, attentionSettings.style != .none else {
            attention.removeAnimation(forKey: "attention")
            Motion.transaction(animated ? .focus : nil) { attention.opacity = 0 }
            return
        }
        guard previous?.generation != mark.generation else { return }
        // A new notification: run the style's animation from the start and
        // rest at its final opacity.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attention.opacity = Motion.attentionRestingOpacity(attentionSettings)
        attention.removeAnimation(forKey: "attention")
        if let animation = Motion.attentionAnimation(attentionSettings) {
            attention.add(animation, forKey: "attention")
        }
        CATransaction.commit()
    }

    private func applyColors() {
        performWithTheme {
            let ringColor = Palette.paneFocusRing(focusRing, override: ringAlphaOverride)
            ring.borderColor = ringColor.cgColor
            glow.borderColor = ringColor.withAlphaComponent(ringColor.alphaComponent * LayoutTunables.focusGlowAlpha.value).cgColor
            glow.shadowColor = ringColor.cgColor
            let attentionColor = attentionMark?.color?.nsColor ?? attentionSettings.color?.nsColor ?? Palette.attention
            attention.borderColor = attentionColor.cgColor
            border.borderColor = (borderStyle.color?.nsColor ?? Palette.paneBorder).cgColor
            // In glass windows the root backdrop owns the ground. An opaque
            // inactive-pane veil would hide the painting and reintroduce the
            // History/terminal mismatch; paneFill is clear in that mode.
            dimLayer.backgroundColor = Palette.paneFill.cgColor
        }
    }
}
