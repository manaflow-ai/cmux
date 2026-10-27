public import AppKit

extension RenderSpring {
    /// A view's backing-layer position, size and opacity (model values) read before a layout moves
    /// it, so the springs that show the move start from the frame it left: the layout commits the
    /// rest frame once and the render server draws the way there (Chrome lays out, then animates
    /// layers: ui/compositor/layer_animator.cc).
    @MainActor public struct LayerRest {
        let position: CGPoint
        let size: CGSize
        let opacity: CGFloat

        /// The rest of `view`'s layer now, or nil when it has no layer.
        public init?(_ view: NSView) {
            guard let layer = view.layer else { return nil }
            position = layer.position
            size = layer.bounds.size
            opacity = CGFloat(layer.opacity)
        }

        /// The moves from this rest to `view`'s layer's current values, one per value that changed.
        public func moves(to view: NSView) -> [Move] {
            guard let layer = view.layer else { return [] }
            var moves: [Move] = []
            if position != layer.position { moves.append(Move(layer, .position, from: position, to: layer.position)) }
            if size != layer.bounds.size { moves.append(Move(layer, .boundsSize, from: size, to: layer.bounds.size)) }
            let target = CGFloat(layer.opacity)
            if opacity != target { moves.append(Move(layer, .opacity, from: opacity, to: target)) }
            return moves
        }
    }
}
