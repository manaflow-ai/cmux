import AppKit
import CmuxNextDesign

/// The decoration props every node accepts: `frame` (`width`, `height`, `minWidth`, `maxWidth`,
/// `minHeight`, `maxHeight`; a number or `"infinity"`) sizes the node around its padding; `background` fills it, `borderColor` and
/// `borderWidth` (1 by default) stroke it inside, `cornerRadius` rounds and clips both;
/// `hoverBackground` washes it while the pointer is over it (local, no script round trip);
/// `rotation` turns it clockwise by that many degrees about its center. `glass` (`chrome`, `popover`,
/// `menu` or `chip`) puts the App's own glass at that level under the node's content: Liquid Glass on
/// macOS 26, the vibrancy material before, the level's opaque surface under Reduce Transparency, rounded
/// by `cornerRadius`. It is paint only: the node's size and its children's frames never change with it,
/// so a look that adds or drops glass moves nothing. An unknown level draws no glass.
extension AppSceneNodeNSView {
    /// One `frame` dimension: a number, or `"infinity"` (fill).
    func frameDimension(_ key: String) -> CGFloat? {
        switch node.props["frame"]?.objectValue?[key] {
        case .number(let value)?: CGFloat(max(0, value))
        case .string("infinity")?: .infinity
        default: nil
        }
    }

    /// `height` clamped to the frame's `minHeight` and finite `maxHeight`.
    func clampedHeight(_ height: CGFloat) -> CGFloat {
        var out = height
        if let low = frameDimension("minHeight") { out = max(out, low) }
        if let high = frameDimension("maxHeight"), high.isFinite { out = min(out, high) }
        return out
    }

    /// A natural width clamped to the frame; a node that fills keeps filling unless the frame caps it
    /// (`maxWidth`: it fills up to that width).
    func clampedNaturalWidth(_ width: CGFloat?) -> CGFloat? {
        let high = frameDimension("maxWidth").flatMap { $0.isFinite ? $0 : nil }
        guard var out = width else { return high }
        if let low = frameDimension("minWidth") { out = max(out, low) }
        if let high { out = min(out, high) }
        return out
    }

    private var cornerRadius: CGFloat { CGFloat(max(0, node.number("cornerRadius") ?? 0)) }

    /// Arms or drops the hover tracking and applies the shape props (on each configure).
    func configureDecorations() {
        if node.props["hoverBackground"]?.stringValue != nil {
            if decorationHover == nil {
                decorationHover = PointerHover(self) { [weak self] hovering in
                    self?.isDecorationHovered = hovering
                    self?.needsDisplay = true
                }
            }
        } else {
            decorationHover = nil
            isDecorationHovered = false
        }
        guard let layer else { return }
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = cornerRadius > 0
        layer.borderWidth = node.props["borderColor"]?.stringValue == nil ? 0 : CGFloat(node.number("borderWidth") ?? 1)
        configureGlass()
        // Painted now too, so a node reads right before its first draw.
        performWithTheme { paintDecorations() }
    }

    /// The fill and border colors, in the theme scope (``paint()``'s caller).
    func paintDecorations() {
        guard let layer else { return }
        let hover = isDecorationHovered ? node.props["hoverBackground"]?.sceneColor : nil
        if hover == nil, let gradient = AppSceneGradient(node.props["background"]) {
            let fill = backgroundGradientLayer(in: layer)
            fill.isHidden = false
            fill.frame = layer.bounds
            gradient.apply(to: fill, size: layer.bounds.size, yDown: fill.contentsAreFlipped())
            layer.backgroundColor = nil
        } else {
            decorationGradient?.isHidden = true
            layer.backgroundColor = (hover ?? node.props["background"]?.sceneColor)?.cgColor
        }
        layer.borderColor = node.props["borderColor"]?.sceneColor?.cgColor
    }

    /// The level a `glass` prop names; nil for none or an unknown one.
    var glassLevel: GlassLevel? { node.string("glass").flatMap(GlassLevel.init(rawValue:)) }

    /// Adds, swaps or drops the glass view for the node's `glass` level. A glass view is not a child: it
    /// sits below every subview, takes no clicks, and only its own frame follows the node's bounds.
    private func configureGlass() {
        guard let level = glassLevel else {
            decorationGlass?.view.removeFromSuperview()
            decorationGlass = nil
            return
        }
        if let current = decorationGlass, current.level == level {
            Self.shapeGlass(current.view, radius: cornerRadius)
            return
        }
        decorationGlass?.view.removeFromSuperview()
        let view = Self.makeGlass(level, radius: cornerRadius)
        view.frame = bounds
        addSubview(view, positioned: .below, relativeTo: nil)
        decorationGlass = (level, view)
    }

    /// The App's surface for `level`: docked (`chrome`) is the sidebar card's glass (a `Panel`'s); the
    /// floating levels are the overlay roles' glass, as the agent pane's host glass draws them.
    static func makeGlass(_ level: GlassLevel, radius: CGFloat) -> NSView {
        let view: NSView
        switch level {
        case .chrome:
            let card = CardSurfaceView(cornerRadius: radius)
            card.takesThemeTint = true
            view = card
        case .popover: view = Glass.makeSurface(.popover, cornerRadius: radius, interactive: false)
        case .menu: view = Glass.makeSurface(.menu, cornerRadius: radius, interactive: false)
        case .chip: view = Glass.makeSurface(.tooltip, cornerRadius: radius, interactive: false)
        }
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }

    /// Follows a changed `cornerRadius` on the glass already in place.
    static func shapeGlass(_ view: NSView, radius: CGFloat) {
        if let surface = view as? OverlaySurfaceView, surface.cornerRadius != radius { surface.cornerRadius = radius }
        if let card = view as? CardSurfaceView, card.cornerRadius != radius { card.cornerRadius = radius }
    }

    /// The layer a gradient `background` draws in, below every child (made once per view).
    private func backgroundGradientLayer(in layer: CALayer) -> CAGradientLayer {
        if let decorationGradient { return decorationGradient }
        let made = CAGradientLayer()
        made.actions = ["colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer.insertSublayer(made, at: 0)
        decorationGradient = made
        return made
    }

    /// The rotation about the node's center (on each layout, since it depends on the size).
    func layoutDecorations() {
        if let glass = decorationGlass?.view, glass.frame != bounds { glass.frame = bounds }
        guard let layer else { return }
        // A gradient's points follow the box's shape: repaint it at the new size.
        if let decorationGradient, !decorationGradient.isHidden, decorationGradient.frame != layer.bounds { needsDisplay = true }
        let degrees = node.number("rotation") ?? 0
        guard degrees != 0 else {
            if !CATransform3DIsIdentity(layer.sublayerTransform) { layer.sublayerTransform = CATransform3DIdentity }
            return
        }
        // Clockwise on screen, about the center: the content's sublayers turn, the node keeps its frame.
        let (cx, cy) = (bounds.midX, bounds.midY)
        var turn = CATransform3DMakeTranslation(cx, cy, 0)
        turn = CATransform3DRotate(turn, CGFloat(-degrees * .pi / 180) * (layer.contentsAreFlipped() ? -1 : 1), 0, 0, 1)
        layer.sublayerTransform = CATransform3DTranslate(turn, -cx, -cy, 0)
    }
}
