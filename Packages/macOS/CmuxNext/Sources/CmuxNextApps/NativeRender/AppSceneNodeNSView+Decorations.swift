import AppKit
import CmuxNextDesign

/// The decoration props every node accepts: `frame` (`width`, `height`, `minWidth`, `maxWidth`,
/// `minHeight`, `maxHeight`; a number or `"infinity"`) sizes the node around its padding; `background` fills it, `borderColor` and
/// `borderWidth` (1 by default) stroke it inside, `cornerRadius` rounds and clips both;
/// `hoverBackground` washes it while the pointer is over it (local, no script round trip);
/// `rotation` turns it clockwise by that many degrees about its center, `scale` sizes it about its
/// center and `offset` moves it, all three on the layer's own transform (the frame does not move);
/// `glow` and `gradient` are drawn in AppSceneNodeNSView+Motion.swift.
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
        // Painted now too, so a node reads right before its first draw.
        performWithTheme { paintDecorations() }
    }

    /// The fill, border, glow and gradient colors, in the theme scope (``paint()``'s caller). An
    /// animated prop change (``changeMotion``) animates them from the colors on screen.
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
            animateColor(layer, \.backgroundColor, "backgroundColor", (hover ?? node.props["background"]?.sceneColor)?.cgColor)
        }
        animateColor(layer, \.borderColor, "borderColor", node.props["borderColor"]?.sceneColor?.cgColor)
        paintGlow()
        paintGradientBackground()
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
        guard let layer else { return }
        // A gradient `background`'s points follow the box's shape: repaint it at the new size.
        if let decorationGradient, !decorationGradient.isHidden, decorationGradient.frame != layer.bounds { needsDisplay = true }
        let parts = SceneTransformParts(scale: node.scaleFactor, degrees: node.rotationDegrees, offset: node.offset)
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
