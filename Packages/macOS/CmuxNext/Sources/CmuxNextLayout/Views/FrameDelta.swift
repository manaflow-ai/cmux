import AppKit
import CmuxNextDesign
import QuartzCore

/// A change of a frame's four components (x, y, width, height): an offset in points or a velocity in
/// points per second. A width or height may be negative.
nonisolated struct FrameDelta: Equatable, Sendable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0

    static let zero = FrameDelta()
}

nonisolated extension FrameDelta {
    /// `from` less `to`, per component.
    init(from: CGRect, to: CGRect) {
        self.init(x: from.minX - to.minX, y: from.minY - to.minY, width: from.width - to.width, height: from.height - to.height)
    }

    /// The velocity of each component of `frame`'s springs.
    init(velocityOf frame: AnimatedFrame) {
        self.init(x: frame.x.velocity, y: frame.y.velocity, width: frame.width.velocity, height: frame.height.velocity)
    }

    func scaled(by factor: CGFloat) -> FrameDelta {
        FrameDelta(x: x * factor, y: y * factor, width: width * factor, height: height * factor)
    }
}

nonisolated extension AnimatedFrame {
    /// Not at rest: off its target rect or alpha, or still moving.
    var isOffRest: Bool {
        rect != targetRect || alpha.value != alpha.target
            || x.velocity != 0 || y.velocity != 0 || width.velocity != 0 || height.velocity != 0
    }
}

extension CALayer {
    /// The scalar render-server springs that carry this layer from `offset` off its model frame, at
    /// `velocity`, back to it. The view-frame deltas map onto the anchor point, and onto a superlayer
    /// whose y axis runs against the view's when `flipsY` (``NSView/layerFlipsY``). Its transform is the identity.
    func springMoves(offset: FrameDelta, velocity: FrameDelta, flipsY: Bool) -> [RenderSpring.Move] {
        let start = superlayerDelta(offset, flipsY: flipsY), speed = superlayerDelta(velocity, flipsY: flipsY)
        let components: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("position.x", position.x, start.x, speed.x),
            ("position.y", position.y, start.y, speed.y),
            ("bounds.size.width", bounds.width, start.width, speed.width),
            ("bounds.size.height", bounds.height, start.height, speed.height),
        ]
        var moves: [RenderSpring.Move] = []
        for (keyPath, model, delta, rate) in components where delta != 0 || rate != 0 {
            moves.append(RenderSpring.Move(self, keyPath, from: model + delta, to: model, velocity: rate))
        }
        return moves
    }

    /// A view-frame delta as one of this layer's position and bounds size.
    private func superlayerDelta(_ delta: FrameDelta, flipsY: Bool) -> FrameDelta {
        let minY = flipsY ? -(delta.y + delta.height) : delta.y
        return FrameDelta(x: delta.x + anchorPoint.x * delta.width, y: minY + anchorPoint.y * delta.height,
                          width: delta.width, height: delta.height)
    }
}

extension NSView {
    /// This view's layer places its sublayers with y against this view's y (`convertToLayer(_:)`).
    var layerFlipsY: Bool { convertToLayer(NSPoint(x: 0, y: 1)).y < convertToLayer(NSPoint.zero).y }
}
