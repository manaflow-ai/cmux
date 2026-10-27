import CmuxNextDesign
import CoreGraphics
import QuartzCore

/// A rect's four components as a difference or a rate: an offset from a rest rect in points, or
/// a velocity in points per second.
nonisolated struct RectComponents: Hashable, Sendable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0

    static let zero = RectComponents()

    init(x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 0, height: CGFloat = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// `rect` minus `base`, per component.
    init(_ rect: CGRect, minus base: CGRect) {
        self.init(x: rect.minX - base.minX, y: rect.minY - base.minY, width: rect.width - base.width, height: rect.height - base.height)
    }

    /// The velocity of each of `frame`'s components.
    init(velocityOf frame: AnimatedFrame) {
        self.init(x: frame.x.velocity, y: frame.y.velocity, width: frame.width.velocity, height: frame.height.velocity)
    }

    var isZero: Bool { self == .zero }

    static func + (lhs: RectComponents, rhs: RectComponents) -> RectComponents {
        RectComponents(x: lhs.x + rhs.x, y: lhs.y + rhs.y, width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}

/// The render-server springs still carrying one pane or divider, as values: each additive spring's start
/// offset (shown minus rest) and velocity per component, its begin time on the screen layer's clock and
/// its tuning. What shows at a time is the rest plus ``residual(at:)``, solved on the CPU with the closed
/// form the render server matches (RenderSpringParityTests), so a later change seeds what it adds from what
/// shows without reading `presentation()`. Chrome keeps the same record on the main thread: each
/// `cc::KeyframeModel` holds its curve and start time (cc/animation/keyframe_model.h), and a curve is
/// evaluated at any time (`ScrollOffsetAnimationCurve::GetValue`), so the main thread knows what the
/// compositor shows.
nonisolated struct RenderSpringTrack: Hashable, Sendable {
    /// One additive spring call: the offset it started from, its velocity then, when and on what tuning.
    nonisolated struct Segment: Hashable, Sendable {
        var offset: RectComponents
        var velocity: RectComponents
        var begin: CFTimeInterval
        var parameters: SpringParameters

        /// The spring is within a thousandth of a point of rest, its velocity's reach included (the
        /// render server removed it by then: `RenderSpring.restTolerance` is coarser).
        func hasLanded(at time: CFTimeInterval) -> Bool {
            let reach = max(abs(velocity.x), abs(velocity.y), abs(velocity.width), abs(velocity.height)) / CGFloat(parameters.omega)
            let extent = max(abs(offset.x), abs(offset.y), abs(offset.width), abs(offset.height), 1) + reach
            return time - begin >= parameters.settlingTime(within: min(0.002, 0.001 / Double(extent)))
        }
    }

    private(set) var segments: [Segment] = []

    var isEmpty: Bool { segments.isEmpty }

    /// A spring from `offset` (shown minus rest) at `velocity` began at `begin`. Segments already at
    /// rest by then are dropped, so a track holds only the springs that still move.
    mutating func add(offset: RectComponents, velocity: RectComponents, begin: CFTimeInterval, parameters: SpringParameters) {
        segments.removeAll { $0.hasLanded(at: begin) }
        guard !offset.isZero || !velocity.isZero else { return }
        segments.append(Segment(offset: offset, velocity: velocity, begin: begin, parameters: parameters))
    }

    /// What shows minus the rest at `time`, and its velocity: the sum of every segment's spring.
    func residual(at time: CFTimeInterval) -> (offset: RectComponents, velocity: RectComponents) {
        var offset = RectComponents.zero, velocity = RectComponents.zero
        for segment in segments where !segment.hasLanded(at: time) {
            let elapsed = max(0, time - segment.begin)
            func solve(_ start: CGFloat, _ rate: CGFloat) -> (CGFloat, CGFloat) {
                guard start != 0 || rate != 0 else { return (0, 0) }
                let state = SpringValue.solve(displacement: Double(start), velocity: Double(rate), time: elapsed, parameters: segment.parameters)
                return (CGFloat(state.displacement), CGFloat(state.velocity))
            }
            let x = solve(segment.offset.x, segment.velocity.x), y = solve(segment.offset.y, segment.velocity.y)
            let width = solve(segment.offset.width, segment.velocity.width), height = solve(segment.offset.height, segment.velocity.height)
            offset = offset + RectComponents(x: x.0, y: y.0, width: width.0, height: height.0)
            velocity = velocity + RectComponents(x: x.1, y: y.1, width: width.1, height: height.1)
        }
        return (offset, velocity)
    }

    /// `frame` (at its rest in the model, as a frame the render server carries is) as it shows at `time`:
    /// the residual added to its value and its velocity, its target unchanged.
    func presenting(_ frame: AnimatedFrame, at time: CFTimeInterval) -> AnimatedFrame {
        let residual = residual(at: time)
        guard !residual.offset.isZero || !residual.velocity.isZero else { return frame }
        var shown = frame
        shown.x.value += residual.offset.x
        shown.y.value += residual.offset.y
        shown.width.value += residual.offset.width
        shown.height.value += residual.offset.height
        shown.x.velocity += residual.velocity.x
        shown.y.velocity += residual.velocity.y
        shown.width.velocity += residual.velocity.width
        shown.height.velocity += residual.velocity.height
        return shown
    }
}
