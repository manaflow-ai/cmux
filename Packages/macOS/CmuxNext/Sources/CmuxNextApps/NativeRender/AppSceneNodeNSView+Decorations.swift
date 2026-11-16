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
        layer.masksToBounds = cornerRadius > 0 && node.glow == nil
        layer.borderWidth = node.props["borderColor"]?.stringValue == nil ? 0 : CGFloat(node.number("borderWidth") ?? 1)
        // Painted now too, so a node reads right before its first draw.
        performWithTheme { paintDecorations() }
    }

    /// The fill, border, glow and gradient colors, in the theme scope (``paint()``'s caller). An
    /// animated prop change (``changeMotion``) animates them from the colors on screen.
    func paintDecorations() {
        guard let layer else { return }
        let hover = isDecorationHovered ? node.props["hoverBackground"]?.sceneColor : nil
        animateColor(layer, \.backgroundColor, "backgroundColor", (hover ?? node.props["background"]?.sceneColor)?.cgColor)
        animateColor(layer, \.borderColor, "borderColor", node.props["borderColor"]?.sceneColor?.cgColor)
        paintGlow()
        paintGradientBackground()
    }

    /// The `scale`, `rotation` (clockwise, in degrees) and `offset` about the node's center, as the
    /// layer's own transform (it does not move the node's frame), and the gradient's and glow's
    /// geometry; on each layout, since they depend on the size.
    func layoutDecorations() {
        guard let layer else { return }
        let parts = SceneTransformParts(scale: node.scaleFactor, degrees: node.rotationDegrees, offset: node.offset)
        let space = SceneTransformSpace(layer: layer)
        let target = space.transform(scale: parts.scale, degrees: parts.degrees, offset: parts.offset)
        if !CATransform3DEqualToTransform(layer.transform, target) {
            let from = appliedTransform
            withoutActions { layer.transform = target }
            // From the old value's parts, so a resize alone never animates.
            if let from, from != parts, parts.scale > 0.001 {
                let delta = space.transform(scale: from.scale / parts.scale, degrees: from.degrees - parts.degrees,
                                            offset: CGPoint(x: from.offset.x - parts.offset.x, y: from.offset.y - parts.offset.y))
                animateAdditive(layer, "transform", from: NSValue(caTransform3D: delta), zero: NSValue(caTransform3D: CATransform3DIdentity))
            }
        }
        appliedTransform = parts
        layoutGradientBackground()
        layoutGlowPath()
    }
}

/// The parts of a node's own transform (``AppSceneNodeNSView/layoutDecorations()``).
struct SceneTransformParts: Equatable {
    var scale: CGFloat
    var degrees: CGFloat
    var offset: CGPoint
}
