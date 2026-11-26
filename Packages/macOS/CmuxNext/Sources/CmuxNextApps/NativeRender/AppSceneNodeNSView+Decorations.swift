import AppKit
import CmuxNextDesign

/// The decoration props every node accepts: `frame` (`width`, `height`, `minWidth`, `maxWidth`,
/// `minHeight`, `maxHeight`; a number or `"infinity"`) sizes the node around its padding; `background` fills it, `borderColor` and
/// `borderWidth` (1 by default) stroke it inside, `cornerRadius` rounds and clips both;
/// `hoverBackground` washes it while the pointer is over it (local, no script round trip);
/// `rotation` turns it clockwise by that many degrees about its center, `scale` sizes it about its
/// center and `offset` (`{x, y}` points) moves its drawing first, so the rotation turns the offset too
/// (a clock hand offset by half its length turns about the face's center), all three on the layer's
/// own transform (the frame does not move); `position` (`{x, y}`, points or, with `unit: "fraction"`,
/// 0...1 of the parent) places a ZStack child's center (``AppSceneZStackNSView``); `glow` and
/// `gradient` are drawn in AppSceneNodeNSView+Motion.swift.
/// `glass` (`chrome`, `popover`, `menu` or `chip`) puts the App's own glass at that level under the node's
/// content: Liquid Glass on macOS 26, the vibrancy material before, the level's opaque surface under Reduce
/// Transparency, rounded by `cornerRadius`; it replaces `background`, a gradient one too. It is paint only:
/// the node's size and its children's frames never change with it, so a look that adds or drops glass moves
/// nothing. An unknown level draws no glass.
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
        // A glow is a shadow outside the bounds: a node that glows rounds without clipping.
        layer.masksToBounds = clipsContent || (cornerRadius > 0 && node.glow == nil)
        layer.borderWidth = node.props["borderColor"]?.stringValue == nil ? 0 : CGFloat(node.number("borderWidth") ?? 1)
        configureGlass()
        // Painted now too, so a node reads right before its first draw.
        performWithTheme { paintDecorations() }
    }

    /// The fill, border, glow and gradient colors, in the theme scope (``paint()``'s caller). An
    /// animated prop change (``changeMotion``) animates them from the colors on screen.
    func paintDecorations() {
        guard let layer else { return }
        let hover = isDecorationHovered ? node.props["hoverBackground"]?.sceneColor : nil
        // Glass replaces the fill, a gradient one too (the glass view sits over the layer's own fill).
        if glassLevel != nil {
            decorationGradient?.isHidden = true
            layer.backgroundColor = nil
        } else if hover == nil, let gradient = AppSceneGradient(node.props["background"]) {
            let fill = backgroundGradientLayer(in: layer)
            fill.isHidden = false
            fill.frame = layer.bounds
            gradient.apply(to: fill, size: layer.bounds.size, yDown: fill.contentsAreFlipped())
            layer.backgroundColor = nil
        } else {
            decorationGradient?.isHidden = true
            animateColor(layer, \.backgroundColor, "backgroundColor", (hover ?? node.props["background"]?.sceneColor)?.cgColor)
        }
        animateColor(layer, \.borderColor, "borderColor", node.props["borderColor"]?.sceneColor?.cgColor)
        paintGlow()
        paintGradientBackground()
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

    /// The `scale`, `rotation` (clockwise, in degrees) and `offset` about the node's center, as the
    /// layer's own transform (it does not move the node's frame), and the gradients' and glow's
    /// geometry; on each layout, since they depend on the size.
    func layoutDecorations() {
        if let glass = decorationGlass?.view, glass.frame != bounds { glass.frame = bounds }
        guard let layer else { return }
        // A gradient `background`'s points follow the box's shape: repaint it at the new size.
        if let decorationGradient, !decorationGradient.isHidden, decorationGradient.frame != layer.bounds { needsDisplay = true }
        let parts = SceneTransformParts(scale: node.scaleFactor, degrees: node.rotationDegrees, offset: node.offset.turned(by: node.rotationDegrees))
        let space = SceneTransformSpace(layer: layer)
        let target = space.transform(scale: parts.scale, degrees: parts.degrees, offset: parts.offset)
        if !CATransform3DEqualToTransform(layer.transform, target) {
            let from = appliedTransform
            withoutActions { layer.transform = target }
            // From the old value's parts, so a resize alone never animates.
            if let from, from != parts { animateTransform(layer, from: from, to: parts, in: space) }
        }
        appliedTransform = parts
        layoutGradientBackground()
        layoutGlowPath()
    }

    /// Puts the node's own transform back after AppKit moved its layer (the parts last laid out).
    func reassertTransform() {
        guard let layer, let parts = appliedTransform else { return }
        let target = SceneTransformSpace(layer: layer).transform(scale: parts.scale, degrees: parts.degrees, offset: parts.offset)
        if !CATransform3DEqualToTransform(layer.transform, target) { withoutActions { layer.transform = target } }
    }

    /// Animates the own transform from `from`'s parts to `to`'s, additively. Core Animation adds an
    /// additive transform as `delta · model` and turns a matrix the short way, so the scale and
    /// offset change is one exact delta (`from · model⁻¹`, with the new rotation) and the rotation
    /// change is pieces of at most 90° about the center that add up (0 to 270 turns 270 clockwise;
    /// 0 to 360, once round).
    private func animateTransform(_ layer: CALayer, from: SceneTransformParts, to: SceneTransformParts, in space: SceneTransformSpace) {
        // A target scale of 0 has no inverse: the delta is taken against a vanishing one.
        let model = space.transform(scale: max(to.scale, 0.001), degrees: to.degrees, offset: to.offset)
        let identity = NSValue(caTransform3D: CATransform3DIdentity)
        if from.scale != to.scale || from.offset != to.offset {
            let start = space.transform(scale: from.scale, degrees: to.degrees, offset: from.offset)
            let delta = CATransform3DConcat(start, CATransform3DInvert(model))
            animateAdditive(layer, "transform", from: NSValue(caTransform3D: delta), zero: identity)
        }
        let turn = from.degrees - to.degrees
        guard turn != 0 else { return }
        let pieces = Int((abs(turn) / 90).rounded(.up))
        let piece = space.transform(degrees: turn / CGFloat(pieces))
        for _ in 0..<pieces { animateAdditive(layer, "transform", from: NSValue(caTransform3D: piece), zero: identity) }
    }
}

/// The parts of a node's own transform (``AppSceneNodeNSView/layoutDecorations()``).
struct SceneTransformParts: Equatable {
    var scale: CGFloat
    var degrees: CGFloat
    var offset: CGPoint
}

extension CGPoint {
    /// This offset (+y down on screen) turned `degrees` clockwise: an offset drawn before a rotation.
    func turned(by degrees: CGFloat) -> CGPoint {
        guard degrees != 0, self != .zero else { return self }
        let radians = degrees * .pi / 180
        return CGPoint(x: x * cos(radians) - y * sin(radians), y: x * sin(radians) + y * cos(radians))
    }
}
