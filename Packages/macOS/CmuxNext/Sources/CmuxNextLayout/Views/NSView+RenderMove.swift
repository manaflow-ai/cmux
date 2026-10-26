import AppKit
import CmuxNextDesign
import QuartzCore

extension NSView {
    /// The springs that show this view's backing layer moving from `from` (its superview's coordinates,
    /// moving at `velocity`) to its frame now, its rest: one scalar spring per position and size component,
    /// so a velocity handed over from a CPU spring carries on (`RenderSpring.Move(_:_:from:to:velocity:)`).
    /// The start geometry comes from the superview's layer conversion, so the frame is set once, at rest,
    /// and nothing lays out at `from`. Empty without a layer or a superview.
    func renderSpringMoves(from: CGRect, velocity: RectComponents) -> [RenderSpring.Move] {
        guard let layer, let superview else { return [] }
        let axes = RenderLayerAxes(superview)
        let anchor = layer.anchorPoint
        let start = superview.convertToLayer(from), rest = superview.convertToLayer(frame)
        let startPosition = RenderLayerAxes.position(of: start, anchor: anchor), restPosition = RenderLayerAxes.position(of: rest, anchor: anchor)
        let rate = axes.velocity(velocity, anchor: anchor)
        // Offsets from the rest in the superlayer's space, on the layer's own rest values.
        let position = layer.position, size = layer.bounds.size
        return [
            RenderSpring.Move(layer, .positionX, from: position.x + startPosition.x - restPosition.x, to: position.x, velocity: rate.position.x),
            RenderSpring.Move(layer, .positionY, from: position.y + startPosition.y - restPosition.y, to: position.y, velocity: rate.position.y),
            RenderSpring.Move(layer, .boundsWidth, from: size.width + start.width - rest.width, to: size.width, velocity: rate.size.width),
            RenderSpring.Move(layer, .boundsHeight, from: size.height + start.height - rest.height, to: size.height,
                              velocity: rate.size.height),
        ]
    }
}

/// How a view's interior axes map to its layer's (`NSView.convertToLayer`): a scale per axis, negative
/// where the layer's axis runs the other way (a flipped view on an unflipped layer).
nonisolated struct RenderLayerAxes: Hashable, Sendable {
    var x: CGFloat
    var y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    @MainActor
    init(_ view: NSView) {
        let origin = view.convertToLayer(CGRect.zero).origin
        x = view.convertToLayer(CGRect(x: 1, y: 0, width: 0, height: 0)).minX - origin.x
        y = view.convertToLayer(CGRect(x: 0, y: 1, width: 0, height: 0)).minY - origin.y
    }

    /// A layer's position for the frame `rect` (layer space) with `anchor` (an identity transform).
    static func position(of rect: CGRect, anchor: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height)
    }

    /// The layer's position and size velocities for a frame moving at `velocity` in the view's space: on an
    /// axis that runs the other way the layer's min edge is the view's max edge.
    func velocity(_ velocity: RectComponents, anchor: CGPoint) -> (position: CGPoint, size: CGSize) {
        let minX = x >= 0 ? x * velocity.x : x * (velocity.x + velocity.width)
        let minY = y >= 0 ? y * velocity.y : y * (velocity.y + velocity.height)
        let size = CGSize(width: abs(x) * velocity.width, height: abs(y) * velocity.height)
        return (CGPoint(x: minX + anchor.x * size.width, y: minY + anchor.y * size.height), size)
    }
}
