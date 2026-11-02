import AppKit

/// The band some ``HomeTopFadeStyle``s draw over the transcript's top, under the header controls
/// (HostView+TopFade.swift places it and sets the rows' mask). Everything here is a layer the render
/// server composites as the rows scroll: no drawing, no per-frame work. Takes no clicks.
final class HomeTopFadeView: NSView {
    let style: HomeTopFadeStyle
    /// The pill's bottom, from the pane's top: where the bands and the hard cut end.
    static var pillBottom: CGFloat { PaneHeaderView.pillCenterY + PaneHeaderView.pillHeight / 2 }
    /// How far under the pill's bottom the progressive blur and the tint run out.
    static let tail: CGFloat = 28
    /// The edge shadow's depth under the cut.
    static let shadowDepth: CGFloat = 10

    private let root = CALayer()
    private var effect: NSVisualEffectView?
    private let solid = CALayer()
    private let hairline = CALayer()
    /// The band's gradient (read by tests: its colours are the band as drawn).
    private(set) var gradient = CAGradientLayer()
    /// progressiveBlur: Gaussian backdrops, weakest to strongest, each masked to end higher up, so the
    /// blur grows toward the top (a variable blur built from the public mask and the backdrops
    /// HeaderBackdropView already uses).
    private var blurs: [(layer: CALayer, mask: CAGradientLayer, solidTo: CGFloat, clearAt: CGFloat)] = []
    private(set) var reducedTransparency = false
    /// edgeShadow: rows sit above the cut (scrolled), so the shadow shows.
    private(set) var scrolledUnder = false

    /// The view's height for its style: the band, plus its tail or shadow.
    var height: CGFloat {
        switch style {
        case .progressiveBlur, .backgroundTint: Self.pillBottom + Self.tail
        case .edgeShadow: Self.pillBottom + Self.shadowDepth
        default: Self.pillBottom + 6
        }
    }

    init(style: HomeTopFadeStyle) {
        self.style = style
        super.init(frame: .zero)
        root.isGeometryFlipped = true
        root.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer = root
        wantsLayer = true
        for l in [solid, hairline, gradient] as [CALayer] {
            l.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "colors": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        }
        build()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func build() {
        reducedTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let usesBlur = style == .progressiveBlur || style == .materialHairline
        if usesBlur, reducedTransparency {
            // Reduce Transparency: an opaque band in the background with the hairline, no blur.
            root.addSublayer(solid)
            root.addSublayer(hairline)
            return
        }
        switch style {
        case .progressiveBlur:
            let pill = Self.pillBottom, end = pill + Self.tail
            for (radius, solidTo, clearAt) in [(CGFloat(2), pill + 4, end), (6, pill - 12, pill + 14), (14, 24, pill)] {
                guard let b = HeaderBackdropView.backdrop(radius: radius) else { continue }
                let m = CAGradientLayer()
                m.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull()]
                m.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
                b.mask = m
                b.actions = ["bounds": NSNull(), "position": NSNull()]
                root.addSublayer(b)
                blurs.append((b, m, solidTo, clearAt))
            }
            // A faint wash of the background over the blur, so light text on a busy row stays calm.
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            root.addSublayer(gradient)
        case .materialHairline:
            let e = NSVisualEffectView(frame: .zero)
            e.material = .headerView
            e.blendingMode = .withinWindow
            e.state = .active
            addSubview(e)
            effect = e
            root.addSublayer(hairline)
            hairline.zPosition = 1
        case .edgeShadow:
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradient.isHidden = true
            root.addSublayer(gradient)
            root.addSublayer(hairline)
            hairline.isHidden = true
        case .backgroundTint:
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            root.addSublayer(gradient)
        case .glassBand, .softMask, .belowPill, .messagesBar:
            break
        }
    }

    /// The pane's background and appearance (the theme's; a clear background is the see-through window).
    func applyColors(background: NSColor, light: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let opaque = background.withAlphaComponent(1)
        solid.backgroundColor = opaque.cgColor
        hairline.backgroundColor = (light ? NSColor(white: 0, alpha: 0.12) : NSColor(white: 1, alpha: 0.10)).cgColor
        effect?.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        switch style {
        case .progressiveBlur:
            gradient.colors = [background.withAlphaComponent(0.55 * background.alphaComponent).cgColor,
                               background.withAlphaComponent(0.25 * background.alphaComponent).cgColor,
                               background.withAlphaComponent(0).cgColor]
        case .backgroundTint:
            // The chat's own colour at the chat's own alpha: the header is the same veil as the rest
            // of Home (the user, 2026-10-31). Over a clear chat fill (a see-through window, a
            // background image) it draws nothing and the rows fade instead (`topMaskStops`); at full
            // opacity it was a flat bar over the picture.
            let a = background.alphaComponent
            gradient.colors = [background.cgColor, background.cgColor, background.withAlphaComponent(0.6 * a).cgColor,
                               background.withAlphaComponent(0).cgColor]
        case .edgeShadow:
            let shade = NSColor(white: 0, alpha: light ? 0.10 : 0.35)
            gradient.colors = [shade.cgColor, shade.withAlphaComponent(0).cgColor]
        default:
            break
        }
        CATransaction.commit()
    }

    /// edgeShadow: shows the shadow and hairline only while rows sit above the cut. Cheap: a no-op unless it flips.
    func setScrolledUnder(_ under: Bool) {
        guard under != scrolledUnder else { return }
        scrolledUnder = under
        guard style == .edgeShadow else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.isHidden = !under
        hairline.isHidden = !under
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = max(1, bounds.height), band = Self.pillBottom + 6
        let px = 1 / max(1, window?.backingScaleFactor ?? 2)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        solid.frame = CGRect(x: 0, y: 0, width: w, height: band)
        effect?.frame = CGRect(x: 0, y: 0, width: w, height: band)
        switch style {
        case .edgeShadow:
            hairline.frame = CGRect(x: 0, y: Self.pillBottom, width: w, height: px)
            gradient.frame = CGRect(x: 0, y: Self.pillBottom, width: w, height: Self.shadowDepth)
        default:
            hairline.frame = CGRect(x: 0, y: band - px, width: w, height: px)
            gradient.frame = bounds
        }
        if style == .backgroundTint {
            let p = Double((PaneHeaderView.pillCenterY) / h), q = Double((Self.pillBottom + 8) / h)
            gradient.locations = [0, NSNumber(value: p), NSNumber(value: q), 1]
        }
        for b in blurs {
            b.layer.frame = bounds
            b.mask.frame = bounds
            b.mask.locations = [0, NSNumber(value: Double(min(b.solidTo, b.clearAt) / h)), NSNumber(value: Double(min(h, b.clearAt) / h))]
        }
        CATransaction.commit()
    }
}
