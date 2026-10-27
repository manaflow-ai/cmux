public import AppKit
public import QuartzCore

extension RenderSpring {
    /// Where a view's layer showed before a change laid it out at rest in the change's turn: the model
    /// values of the named keys, read now. ``moves()``, called after that layout, gives the springs that
    /// carry each key the layout changed from there to its rest, so the change starts from what showed
    /// (Chrome's layer animator starts a property from its current value, `ui/compositor/layer_animator.h`).
    public struct Start {
        private let view: NSView
        private let layer: CALayer
        private let values: [(key: RenderSpringKey<CGFloat>, value: CGFloat)]

        /// Notes `view`'s layer now; nil while the view is hidden or has no layer.
        public init?(_ view: NSView, keys: [RenderSpringKey<CGFloat>]) {
            guard !view.isHidden, let layer = view.layer else { return nil }
            self.view = view
            self.layer = layer
            values = keys.compactMap { key in key.value(of: layer).map { (key: key, value: $0) } }
        }

        /// The springs from the noted values to the layer's model values now; none when the layout hid the
        /// view or replaced its layer.
        public func moves() -> [Move] {
            guard !view.isHidden, view.layer === layer else { return [] }
            return values.compactMap { start in
                guard let rest = start.key.value(of: layer), rest != start.value else { return nil }
                return Move(layer, start.key, from: start.value, to: rest)
            }
        }
    }
}
