import AppKit
import CmuxNextDesign
import Observation
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

    /// What the inactive dim paints: the pane fill (clear over a
    /// see-through window), or the Ghostty config's `unfocused-split-fill`
    /// (the theme background when nil) over any window, as Ghostty.app.
    enum DimFill: Equatable {
        case pane
        case ghostty(ThemeRGB?)
    }

    private let border = CALayer()
    private let ring = CALayer()
    private let glowClip = CALayer()
    private let glow = CALayer()
    private let attention = CALayer()
    /// The attention ring's layer (for the glow, `PaneOverlayView+Glow`).
    var attentionLayer: CALayer { attention }
    private let dimLayer = CALayer()
    /// The ring flashed when focus arrives without a click (`focus.flashOnMove`): its own layer, so
    /// the ring's opacity updates never cut the flash short.
    private let focusFlash = CALayer()
    /// Chats sit directly on the window glass. These decorative layers otherwise draw above
    /// their page menus when the overlay plane is hosted above Chromium child windows.
    var showsContentFrame = true {
        didSet {
            guard showsContentFrame != oldValue else { return }
            for layer in [border, ring, glowClip, focusFlash] { layer.isHidden = !showsContentFrame }
        }
    }
    /// This pane was the focused one at the last update.
    private var isFocusedPane = false
    private var padding: CGFloat = 0
    private var cornerRadius: CGFloat = 0
    private var headerHeight: CGFloat = 0
    private var footerHeight: CGFloat = 0
    private var focusRing = FocusRingSettings()
    private var ringAlphaOverride: CGFloat?
    private var attentionSettings = AttentionSettings()
    /// The attention ring glows (`notifications.attention.ringStyle` glow), `PaneOverlayView+Glow`.
    var ringGlows: Bool { attentionSettings.ringStyle == .glow }
    private var attentionMark: AttentionMark?
    /// The source color of the ring flashing out: the flash keeps it after its mark is gone.
    private var dismissingColor: ThemeRGB?
    /// The ring shown or flashing out marks an agent chat (`AttentionMark.agentChat`).
    private var attentionAgentChat = false
    /// The ring's strength (`AttentionHighlightLook`, Debug Settings; cx-epgo).
    private var attentionLook = AttentionHighlightLook.tunable.defaultValue
    /// One observation of the look is registered at a time.
    private var observesAttentionLook = false
    private var borderStyle = Border(shows: false)
    private var dimFill = DimFill.pane
    private var excluded: [CGRect] = []
    private var excludedBounds: CGRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glowClip.masksToBounds = true
        glowClip.addSublayer(glow)
        glow.shadowOffset = .zero
        glow.shadowOpacity = 1
        for sublayer in [dimLayer, border, ring, glowClip, attention, focusFlash] {
            sublayer.opacity = 0
            layer?.addSublayer(sublayer)
        }
        glow.opacity = 1
        ring.borderWidth = 1
        applyRingGlow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The attention ring's running animations and model opacity (for tests and `debug.layers`).
    var attentionAnimationKeys: [String] { attention.animationKeys() ?? [] }
    var attentionOpacity: Float { attention.opacity }

    /// Whether the focus ring or glow is showing (for `debug.layers`).
    var showsRing: Bool { showsContentFrame && (ring.opacity > 0 || glowClip.opacity > 0) }
    /// Whether the hairline border is showing (for `debug.layers`).
    var showsBorder: Bool { showsContentFrame && border.opacity > 0 }

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

    func setShape(padding: CGFloat, cornerRadius: CGFloat, headerHeight: CGFloat, footerHeight: CGFloat = 0) {
        guard padding != self.padding || cornerRadius != self.cornerRadius || headerHeight != self.headerHeight
            || footerHeight != self.footerHeight else { return }
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.headerHeight = headerHeight
        self.footerHeight = footerHeight
        layoutLayers()
    }

    /// The rect the focus ring and glow trace, in this view's coordinates
    /// (for tests and `debug.layers`).
    var ringFrame: CGRect { ring.frame }
    /// The color the focus ring strokes with (for tests).
    var ringColor: CGColor? { ring.borderColor }
    /// The border's line width in points and color override (for tests).
    var borderWidth: CGFloat { border.borderWidth }
    var borderColor: ThemeRGB? { borderStyle.color }

    private func layoutLayers() {
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = cornerRadius
        let padded = PaneChromeGeometry.contentRect(forCell: bounds, style: style)
        let rect = PaneChromeGeometry.roundedRect(inPadded: padded, headerHeight: headerHeight, footerHeight: footerHeight)
        let radius = PaneChromeGeometry.cornerRadius(for: rect, style: style)
        let ringRadius = focusRing.cornerRadius.map { min($0, min(rect.width, rect.height) / 2) } ?? radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [border, attention] {
            sublayer.frame = rect
            sublayer.cornerRadius = radius
        }
        for sublayer in [ring, glowClip, focusFlash] {
            sublayer.frame = rect
            sublayer.cornerRadius = ringRadius
        }
        dimLayer.frame = padded
        dimLayer.cornerRadius = radius
        // The dim covers the whole padded rect: only the corners the content
        // area shares with it round (a header squares the top ones, a footer
        // the bottom ones). The view is flipped, so maxY is the bottom.
        var corners: CACornerMask = []
        if headerHeight <= 0 { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if footerHeight <= 0 { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        dimLayer.maskedCorners = corners
        glow.frame = glowClip.bounds
        glow.cornerRadius = ringRadius
        border.borderWidth = borderStyle.width ?? PaneChromeGeometry.hairlineWidth(scale: scale)
        ring.borderWidth = focusRing.width
        focusFlash.borderWidth = max(focusRing.width, Self.flashMinimumWidth)
        glow.borderWidth = focusRing.width
        glow.shadowRadius = max(2, focusRing.width * LayoutTunables.focusGlowRadiusFactor.value)
        attention.borderWidth = attentionSettings.width
        attention.shadowPath = Self.ringOutline(size: rect.size, radius: radius, width: attentionSettings.width)
        CATransaction.commit()
    }

    /// `showsRing`: this pane is focused and the ring should mark it.
    /// `attention`: the pane's unread mark, nil when none.
    /// Hides the overlay inside `rects` (its own coordinates): a docked
    /// column covering this strip pane, a pane in front of it. Empty removes the mask.
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
        // Subtracted, not even-odd: a docked column and a pane in front can overlap.
        let path = rects.reduce(CGPath(rect: bounds, transform: nil)) { $0.subtracting(CGPath(rect: $1, transform: nil)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.fillRule = .nonZero
        mask.frame = bounds
        mask.path = path
        CATransaction.commit()
        if layer.mask !== mask { layer.mask = mask }
    }

    func update(showsRing: Bool, dim: CGFloat, dimFill: DimFill = .pane, focusRing: FocusRingSettings, ringAlphaOverride: CGFloat? = nil,
                border borderStyle: Border, attention mark: AttentionMark?, attentionSettings: AttentionSettings,
                readByEntry: Bool = false, focused: Bool = false, flashesFocus: Bool = false, animated: Bool) {
        self.dimFill = dimFill
        // The pane's own look and flash count: an agent chat's or a terminal's. A ring going away
        // keeps its pane's look through its dismiss flash.
        attentionAgentChat = mark?.agentChat ?? attentionMark?.agentChat ?? attentionAgentChat
        let attentionSettings = attentionSettings.surface(agentChat: attentionAgentChat)
        let shapeChanged = focusRing != self.focusRing || attentionSettings != self.attentionSettings
            || borderStyle.width != self.borderStyle.width
        let showsBorder = borderStyle.shows
        let glowChanged = attentionSettings.ringStyle != self.attentionSettings.ringStyle
        self.borderStyle = borderStyle
        self.focusRing = focusRing
        self.ringAlphaOverride = ringAlphaOverride
        self.attentionSettings = attentionSettings
        if shapeChanged { layoutLayers() }
        if glowChanged {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyRingGlow()
            // A look without glow (ring, none) stops a dismiss flash's glow that is running.
            if !ringGlows { attention.removeAnimation(forKey: "attention-dismiss-glow") }
            CATransaction.commit()
        }
        let style = showsRing ? focusRing.effectiveStyle : .none
        // A ring that rests invisible (the flash look) keeps the border.
        let marksAttention = mark != nil && attentionSettings.drawsRing
            && Motion.attentionRestingOpacity(attentionSettings, look: AttentionHighlightLook.tunable.value) > 0
        // Focus moving between panes never crossfades two rings (cx-f6i7): a
        // ring or glow leaving goes at once and the one arriving eases in, as
        // a hover fill does; the plain border comes back at once under a ring
        // that leaves and fades under one that arrives. The dim is one pane's
        // state and fades both ways.
        let targets: [(CALayer, Float)] = [
            (ring, style == .ring ? 1 : 0), (glowClip, style == .glow ? 1 : 0),
            (border, showsBorder && style == .none && !marksAttention ? 1 : 0),
        ]
        // Split before either write: once a leaving layer is set, it no longer reads as leaving.
        let leaving = targets.map { layer, value in layer === border ? value > layer.opacity : value < layer.opacity }
        Motion.panes.transaction(nil) {
            for ((layer, value), leaves) in zip(targets, leaving) where leaves {
                layer.removeAnimation(forKey: "opacity")
                layer.opacity = value
            }
        }
        Motion.feedback.transaction(animated ? .focus : nil) {
            for ((layer, value), leaves) in zip(targets, leaving) where !leaves { layer.opacity = value }
        }
        Motion.feedback.transaction(animated ? .paneDim : nil) { dimLayer.opacity = Float(dim) }
        if Self.flashesFocus(wasFocused: isFocusedPane, focused: focused, requested: flashesFocus, ringShows: style != .none) {
            Motion.feedback.set(focusFlash, "opacity", to: Float(0), fade: .focusFlash, from: Float(1))
        } else if !focused, focusFlash.animation(forKey: "opacity") != nil {
            // Focus moved on: the flash leaves with it.
            focusFlash.removeAnimation(forKey: "opacity")
        }
        isFocusedPane = focused
        applyAttention(mark, readByEntry: readByEntry, animated: animated)
        applyColors()
    }

    /// Whether the ring flashes on this pane: focus just arrived, the screen asked for the flash
    /// (`ScreenContentView.requestsFocusFlash`, which also needs motion allowed) and no ring
    /// already marks it.
    static func flashesFocus(wasFocused: Bool, focused: Bool, requested: Bool, ringShows: Bool) -> Bool {
        requested && focused && !wasFocused && !ringShows
    }

    /// The flash's stroke is at least this wide, so a 1 pt ring setting still reads at a glance.
    static let flashMinimumWidth: CGFloat = 2

    /// Reads the highlight look and applies a Debug Settings change once,
    /// without replaying the ring's animation (no polling).
    private func observedAttentionLook() -> AttentionHighlightLook {
        guard !observesAttentionLook else { return attentionLook }
        observesAttentionLook = true
        return withObservationTracking {
            AttentionHighlightLook.tunable.value
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.attentionLookChanged() }
        }
    }

    private func attentionLookChanged() {
        observesAttentionLook = false
        attentionLook = observedAttentionLook()
        if attentionMark != nil, attentionSettings.drawsRing {
            Motion.feedback.transaction(.focus) { attention.opacity = Motion.attentionRestingOpacity(attentionSettings, look: attentionLook) }
        }
        applyColors()
    }

    /// `readByEntry`: the mark went away because the person went into the
    /// pane (a click, a key, an open): the ring blinks out, as cmux classic's
    /// dismiss flash did. A mark cleared any other way (Mark Read, a timeout,
    /// a mute, another device) just fades.
    private func applyAttention(_ mark: AttentionMark?, readByEntry: Bool, animated: Bool) {
        let previous = attentionMark
        attentionMark = mark
        attentionLook = observedAttentionLook()
        guard let mark, attentionSettings.drawsRing else {
            attention.removeAnimation(forKey: "attention")
            // The look turned off (none) mid-flash: the flash and its glow go with it.
            if !attentionSettings.drawsRing {
                attention.removeAnimation(forKey: "attention-dismiss")
                attention.removeAnimation(forKey: "attention-dismiss-glow")
            }
            if previous != nil, readByEntry, animated,
               let flash = Motion.indicators.attentionDismissAnimation(attentionSettings, look: attentionLook) {
                dismissingColor = previous?.color
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                attention.opacity = 0
                attention.add(flash, forKey: "attention-dismiss")
                addFlashGlow(for: flash)
                CATransaction.commit()
                return
            }
            Motion.feedback.transaction(animated ? .focus : nil) { attention.opacity = 0 }
            return
        }
        attention.removeAnimation(forKey: "attention-dismiss")
        attention.removeAnimation(forKey: "attention-dismiss-glow")
        dismissingColor = nil
        guard previous?.generation != mark.generation else { return }
        // A new notification: run the style's animation from the start and
        // rest at its final opacity (the steady ring swells from its rest when
        // it already shows, rather than dropping out first).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attention.opacity = Motion.attentionRestingOpacity(attentionSettings, look: attentionLook)
        attention.removeAnimation(forKey: "attention")
        if !mark.quiet, let animation = Motion.indicators.attentionAnimation(attentionSettings, look: attentionLook, showing: previous != nil) {
            attention.add(animation, forKey: "attention")
        }
        CATransaction.commit()
    }

    private func applyColors() {
        performWithTheme {
            let ringColor = Palette.paneFocusRing(focusRing, override: ringAlphaOverride)
            ring.borderColor = ringColor.cgColor
            // The flash marks a move, so it draws at least at standard contrast.
            let flashAlpha = max(ringAlphaOverride ?? focusRing.contrast.ringAlpha, FocusRingContrast.standard.ringAlpha)
            focusFlash.borderColor = Palette.paneFocusRing(focusRing, override: flashAlpha).cgColor
            glow.borderColor = ringColor.withAlphaComponent(ringColor.alphaComponent * LayoutTunables.focusGlowAlpha.value).cgColor
            glow.shadowColor = ringColor.cgColor
            let attentionColor = (attentionMark?.color ?? dismissingColor)?.nsColor ?? attentionSettings.color?.nsColor ?? attentionLook.defaultColor
            attention.borderColor = attentionColor.cgColor
            attention.shadowColor = attentionColor.cgColor
            border.borderColor = (borderStyle.color?.nsColor ?? Palette.paneBorder).cgColor
            // In glass windows the root backdrop owns the ground. An opaque
            // inactive-pane veil would hide the painting and reintroduce the
            // History/terminal mismatch; paneFill is clear in that mode.
            switch dimFill {
            case .pane:
                dimLayer.backgroundColor = Palette.paneFill.cgColor
            case .ghostty(let fill):
                dimLayer.backgroundColor = (fill?.nsColor ?? Palette.surfaceBackground.withAlphaComponent(1)).cgColor
            }
        }
    }
}
