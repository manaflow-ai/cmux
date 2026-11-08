import AppKit
import CmuxNextDesign

/// The decoration props every node accepts, as the SwiftUI renderer's `AppSceneDecorations` applied
/// them: `frame` (`width`, `height`, `minWidth`, `maxWidth`, `minHeight`, `maxHeight`; a number or
/// `"infinity"`) sizes the node around its padding; `background` fills it, `borderColor` and
/// `borderWidth` (1 by default) stroke it inside, `cornerRadius` rounds and clips both;
/// `hoverBackground` washes it while the pointer is over it (local, no script round trip);
/// `rotation` turns it clockwise by that many degrees about its center.
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
        // Painted now too, so a node reads right before its first draw.
        performWithTheme { paintDecorations() }
    }

    /// The fill and border colors, in the theme scope (``paint()``'s caller).
    func paintDecorations() {
        guard let layer else { return }
        let hover = isDecorationHovered ? node.props["hoverBackground"]?.sceneColor : nil
        layer.backgroundColor = (hover ?? node.props["background"]?.sceneColor)?.cgColor
        layer.borderColor = node.props["borderColor"]?.sceneColor?.cgColor
    }

    /// The rotation about the node's center (on each layout, since it depends on the size).
    func layoutDecorations() {
        guard let layer else { return }
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
