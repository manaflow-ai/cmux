import AppKit
import CmuxNextDesign
import QuartzCore

/// The omnibar's rounded background (`OmnibarGlassLook`): at rest the flat
/// theme fill (the default), the glass material or nothing (transparent); a
/// hover lift; a neutral ring while editing; and the plain card fill while it
/// is the top of the suggestion card (the card is opaque, so the bar joins
/// it).
final class OmnibarPillView: NSView {
    enum State { case idle, editing, card }

    /// Focus, blur and the card switch the look at once, on the frame of the
    /// press, as Chrome's omnibox does; only the pointer's hover eases. A
    /// fade here kept the focusing click's editing fill from showing for
    /// several frames after the press (omnibar mouse-down latency).
    var state: State = .idle { didSet { if oldValue != state { refresh(animated: false) } } }
    /// Where the pointer is now (`OmnibarPointer`): a hide, a tab switch or
    /// a window change under a still pointer clears it.
    private var hover: PointerHover?
    private var isHovering: Bool { hover?.isHovering ?? false }
    /// Whether the pointer is over the bar (`debug.omnibar`).
    var debugHovering: Bool { isHovering }
    /// A fill, ring or shadow animation is still running on the bar's layer.
    var debugIsFading: Bool { !(layer?.animationKeys() ?? []).isEmpty }
    /// The look in effect; follows cmux.json live.
    private(set) var look = OmnibarGlassLook.current { didSet { if oldValue != look { rebuildMaterial() } } }
    /// The glass under the bar, built while the look has a material.
    private var glass: GlassPanelView?
    /// Ends with the view (the loop holds it weakly).
    private var lookLoop: ObservationLoop?
    /// The editing ring, drawn outside the bar's edge so the field keeps its whole height (Lucas 2026-11-15: "the ring
    /// should be outside of the input"), its corner the bar's plus the ring's width (concentric). It lives in the pane's
    /// own layer (``ringPlace(ring:)``), over the content area's clip, so the bar can sit one tab gap under the tabs with the
    /// ring whole (Lucas 2026-11-15: the gap from the tab to the bar is the gap above the tab).
    private let ringLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        ringLayer.cornerCurve = .continuous
        ringLayer.zPosition = 1
        // motion: allow the ring's width fades in `refresh`'s Motion.feedback transaction; its frame follows the bar at once.
        ringLayer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(ringLayer)
        rebuildMaterial()
        // The bar's hover eases in and clears at once (`ChromeHover.fade`).
        hover = PointerHover(self) { [weak self] hovering in
            self?.refresh(animated: true, fade: ChromeHover.fade(showing: hovering))
        }
        lookLoop = ObservationLoop { [weak self] in
            let next = OmnibarGlassLook.current
            self?.look = next
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Never clips: AppKit turns clipping on whenever the backing layer's corner radius is set
    /// (`-[NSViewBackingLayer setCornerRadius:]` calls `_mightNeedViewToClipToBounds`), which hid the editing ring drawn
    /// outside the bounds. The fill rounds by its own corner radius and the glass masks itself (`GlassPanelView`).
    override var clipsToBounds: Bool {
        get { false }
        set {} // swiftlint:disable:this unused_setter_value
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Hover is the pill's frame under the pointer (the bar above it takes
    // the clicks); hiding with the pane or leaving the window clears it.
    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
        applyShape()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        hover?.refresh()
        applyShape()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Out of a window, the ring leaves the pane's layer with the bar.
        if window == nil { ringLayer.removeFromSuperlayer() }
        hover?.refresh()
        // A theme repaint skips a pill outside the window (a dark-to-dark
        // theme switch brings no appearance change on return).
        refresh(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Reduce Transparency may have changed since the material was built.
        if drawsGlass != (glass != nil) { rebuildMaterial() } else { refresh(animated: false) }
    }

    override func layout() {
        super.layout()
        applyShape()
    }

    /// Glass draws only with a material and without Reduce Transparency.
    private var drawsGlass: Bool {
        (look.material == .regular || look.material == .clear) && !ReduceTransparency.shared.isEnabled
    }

    private func rebuildMaterial() {
        if drawsGlass {
            let style: Glass.Style = look.material == .clear ? .clear : .regular
            if let glass {
                glass.style = style
            } else {
                let panel = GlassPanelView(style: style, cornerRadius: 0) // glass-level-allow: the omnibar's material and tint are the browser.omnibar look setting (OmnibarGlass), not a fixed level
                panel.translatesAutoresizingMaskIntoConstraints = false
                addSubview(panel, positioned: .below, relativeTo: nil)
                NSLayoutConstraint.activate([
                    panel.leadingAnchor.constraint(equalTo: leadingAnchor),
                    panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                    panel.topAnchor.constraint(equalTo: topAnchor),
                    panel.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                glass = panel
            }
        } else {
            glass?.removeFromSuperview()
            glass = nil
        }
        applyShape()
        refresh(animated: false)
    }

    /// The flat fill's state now.
    private var barState: AddressBarSurface.State { isHovering ? .hover : .rest }

    /// `debug.omnibar` `pointer.bar_style`: the resolved look (fill RGBA in
    /// sRGB 0...1, corner radius, ring width, state and material).
    var debugStyle: [String: Any] {
        let fill = layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        let rgba: [Double] = fill.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent].map(Double.init) } ?? [0, 0, 0, 0]
        let coverage = performWithTheme { Palette.addressBar.resolvedCoverage(look.backgroundOpacity) }
        return ["fill": rgba, "corner_radius": Double(layer?.cornerRadius ?? 0), "ring_width": Double(ringLayer.borderWidth),
                "state": state == .idle ? barState.rawValue : (state == .card ? "card" : "editing"), "material": look.material.rawValue,
                "background_opacity": look.backgroundOpacity, "resolved_coverage": coverage, "glass": glass != nil]
    }

    /// Where the ring goes: around the bar in its own layer; in the pane's layer when it crosses its content area's top
    /// edge (``PaneContentAreaView`` clips to its bounds, which start at the toolbar's top edge); inside the bar's edge,
    /// as before, when the bar touches an edge the pane cannot hold still.
    private enum RingPlace {
        case bar
        case pane(NSView)
        case inside
    }

    /// Only a flipped pane takes the ring over its top edge: there the bar keeps its distance from the pane's top
    /// through a vertical resize, which runs no layout of the bar's own, so the ring needs no window observer to stay on
    /// the bar. A bar on the area's bottom edge (a toolbar at the bottom of a borderless pane) moves with that edge, so
    /// its ring draws inside.
    private func ringPlace(ring: CGFloat) -> RingPlace {
        var view = superview
        while let current = view {
            if current is PaneContentAreaView {
                let around = current.convert(bounds.insetBy(dx: -ring, dy: -ring), from: self)
                let area = current.bounds
                let crossesTop = current.isFlipped ? around.minY < area.minY : around.maxY > area.maxY
                let crossesBottom = current.isFlipped ? around.maxY > area.maxY : around.minY < area.minY
                if crossesBottom { return .inside }
                guard crossesTop else { return .bar }
                guard let pane = current.superview, pane.layer != nil, pane.isFlipped else { return .inside }
                return .pane(pane)
            }
            view = current.superview
        }
        return .bar
    }

    /// The ring's host layer and its frame in that layer, for tests.
    var debugRing: (host: CALayer?, frame: CGRect) { (ringLayer.superlayer, ringLayer.frame) }

    /// The ring around the bar, one ring width outside it, in its host's layer, only while the bar is editing: out of
    /// editing it leaves the host, so a bar that blurs, moves to another pane or hides leaves no ring behind.
    private func placeRing(radius: CGFloat) {
        guard state == .editing, window != nil, layer != nil else {
            ringLayer.removeFromSuperlayer()
            return
        }
        let ring = Metrics.lineWidth(OmnibarStyle.ringWidth)
        let place = ringPlace(ring: ring)
        let host: NSView
        if case .pane(let pane) = place { host = pane } else { host = self }
        guard let hostLayer = host.layer else { return }
        if ringLayer.superlayer !== hostLayer {
            ringLayer.removeFromSuperlayer()
            hostLayer.addSublayer(ringLayer)
        }
        ringLayer.zPosition = host === self ? 1 : 100
        if case .inside = place {
            ringLayer.frame = bounds
            ringLayer.cornerRadius = radius
        } else {
            let around = bounds.insetBy(dx: -ring, dy: -ring)
            // Through the views: a layer-backed view's layer shares its view's coordinates (the layer tree can skip views).
            ringLayer.frame = host === self ? around : host.convert(around, from: self)
            ringLayer.cornerRadius = radius + ring
        }
        ringLayer.isHidden = isHiddenOrHasHiddenAncestor
    }

    private func applyShape() {
        // Open, the pill is the card's top: it takes the card's corner, so its fill does not square off the card's
        // rounder top corners (`OmnibarStyle.cardCornerRadius`).
        let radius = state == .card ? OmnibarStyle.cardCornerRadius
            : look.resolvedCornerRadius(barHeight: bounds.height > 0 ? bounds.height : OmnibarStyle.barHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = radius
        glass?.cornerRadius = radius
        placeRing(radius: radius)
        if look.shadow && drawsGlass && state != .card {
            // The raised elevation step (PopupStyle.elevation2), as every floating surface.
            let elevation = PopupStyle.elevation2
            layer?.shadowOpacity = Float(elevation.alpha)
            layer?.shadowRadius = elevation.layerRadius
            layer?.shadowOffset = elevation.layerOffset()
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        } else {
            layer?.shadowOpacity = 0
            layer?.shadowPath = nil
        }
        CATransaction.commit()
    }

    /// `fade`: how the ring shows on a hover change (`ChromeHover.fade`); a
    /// state change (editing, card) eases. The fill eases in and out
    /// (`ChromeHover.paint`).
    private func refresh(animated: Bool, fade: MotionFade? = .hover) {
        let ring = state == .editing ? OmnibarStyle.ringWidth : 0
        let glassy = drawsGlass && state != .card
        glass?.isHidden = !glassy
        Motion.feedback.transaction(animated ? fade : nil) {
            performWithTheme {
                let fill: NSColor
                if glassy {
                    // The glass draws the surface; the layer adds only the
                    // hover lift over it.
                    fill = isHovering && state == .idle ? OmnibarStyle.chipHoverFill : .clear
                    glass?.tintColor = look.tintColor(boost: state == .editing ? 0.15 : 0)
                    layer?.shadowColor = Palette.shadow.cgColor
                } else if look.material == .transparent {
                    // Flat and clear: no fill at rest or while editing (the
                    // ring shows focus); on hover the toolbar buttons' see-through
                    // hover fill, not the opaque lift; the opaque card top.
                    fill = switch state {
                    case .idle: isHovering && DesignSettings.shared.showsHoverFills ? Palette.hoverFill : .clear
                    case .editing: .clear
                    case .card: OmnibarStyle.cardFill
                    }
                } else {
                    // The flat fill (`AddressBarSurface`): a tonal step over the
                    // toolbar that keeps a see-through window's transparency.
                    fill = state == .idle ? OmnibarStyle.barFill(barState, coverage: look.backgroundOpacity) : OmnibarStyle.cardFill
                }
                // The backing layer takes no implicit action, so the fill
                // fades with an explicit animation: it eases between rest,
                // hover and editing (Reduce Motion: at once); the card top
                // shows at once with the card.
                if let layer {
                    ChromeHover.paint(layer, fill.alphaComponent > 0 ? fill : nil, animated: animated && state != .card, clearing: .hover)
                }
                ringLayer.borderColor = OmnibarStyle.ring.cgColor
            }
            ringLayer.borderWidth = Metrics.lineWidth(ring)
        }
        applyShape()
    }
}

/// The part of the suggestion card behind the bar: the bar's own frame and
/// corners, rounded at the top only. The dropdown panel continues it below
/// the bar, so bar and rows read as one card. With the toolbar at the bottom
/// (`browser.toolbarPosition`) the card opens upward: rounded at the bottom
/// only, the rows above.
final class OmnibarCardTopView: NSView {
    let card = CALayer()
    /// The rows sit above the bar.
    var opensUpward = false {
        didSet { if opensUpward != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        card.cornerCurve = .continuous
        card.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        // The one popup shadow (PopupStyle), as the panel of rows below.
        let elevation = PopupStyle.elevation2
        card.shadowOpacity = Float(elevation.alpha)
        card.shadowRadius = elevation.layerRadius
        card.shadowOffset = elevation.layerOffset()
        layer?.addSublayer(card)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = bounds
        card.cornerRadius = OmnibarStyle.cardCornerRadius
        // The corners away from the rows (the layer's y points up).
        card.maskedCorners = opensUpward ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        // Extend the shadow shape past the seam toward the rows, so no line shows
        // between the two halves (the panel of rows casts no shadow of its own).
        let shape = CGRect(x: 0, y: opensUpward ? 0 : -40, width: bounds.width, height: bounds.height + 40)
        card.shadowPath = CGPath(roundedRect: shape, cornerWidth: OmnibarStyle.cardCornerRadius, cornerHeight: OmnibarStyle.cardCornerRadius, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        performWithTheme {
            card.backgroundColor = OmnibarStyle.cardFill.cgColor
        }
    }
}
