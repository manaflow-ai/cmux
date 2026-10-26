import CmuxNextDesign
import QuartzCore

/// One pane's or divider's move to its rest on the render server: its rest frame in the screen, where its
/// new spring starts as an offset from that rest, and the velocity it starts with.
struct RenderMove {
    var to: CGRect
    var offset: FrameDelta
    var velocity: FrameDelta
    var fromAlpha: CGFloat
    var toAlpha: CGFloat
}

/// One render-server spring call of a pane or divider. It lands once: when Core Animation's springs end
/// (`RenderSpring.Completion`), or earlier when the screen ends it (the item left the screen, or the CPU
/// step took its motion back).
final class RenderSpringCall {
    private var landing: ((_ settles: Bool) -> Void)?

    /// `landing` runs once; `settles` is false when the CPU step moves the item on from where it shows.
    init(landing: @escaping (_ settles: Bool) -> Void) {
        self.landing = landing
    }

    var isPending: Bool { landing != nil }

    func land(settles: Bool = true) {
        guard let landing else { return }
        self.landing = nil
        landing(settles)
    }
}

/// What a pane's or divider's render-server springs add to its rest frame: every spring call since it was
/// last at rest, as values. The springs are additive, so what shows is the rest plus the sum of each call's
/// closed-form spring at the layer's time, and the velocity is the sum of theirs. Nothing reads
/// `presentation()`: Chromium's compositor likewise samples its curves at a time
/// (cc/animation/keyframe_model.cc, `KeyframeModel::TrimTimeToCurrentIteration`).
struct RenderTrack {
    nonisolated struct Part: Sendable {
        /// Where the call's spring started, off the rest it went to.
        var offset: FrameDelta
        var velocity: FrameDelta
        /// The layer's local time the spring began at (`CALayer.convertTime(_:from:)`).
        var begin: CFTimeInterval
        var spring: SpringParameters
    }

    /// The spring rect the springs carry the item to (its frame's target).
    var rest: CGRect
    var parts: [Part] = []
    /// The calls that have not landed.
    var calls: [RenderSpringCall] = []

    init(rest: CGRect) {
        self.rest = rest
    }

    /// The offset from the rest and the velocity at the layer's local `time`.
    func shown(at time: CFTimeInterval) -> (offset: FrameDelta, velocity: FrameDelta) {
        var offset = FrameDelta.zero, velocity = FrameDelta.zero
        for part in parts {
            let elapsed = max(0, time - part.begin)
            func solve(_ start: CGFloat, _ speed: CGFloat) -> (CGFloat, CGFloat) {
                guard start != 0 || speed != 0 else { return (0, 0) }
                let state = SpringValue.solve(displacement: Double(start), velocity: Double(speed), time: elapsed, parameters: part.spring)
                return (CGFloat(state.displacement), CGFloat(state.velocity))
            }
            let x = solve(part.offset.x, part.velocity.x), y = solve(part.offset.y, part.velocity.y)
            let width = solve(part.offset.width, part.velocity.width), height = solve(part.offset.height, part.velocity.height)
            offset = FrameDelta(x: offset.x + x.0, y: offset.y + y.0, width: offset.width + width.0, height: offset.height + height.0)
            velocity = FrameDelta(x: velocity.x + x.1, y: velocity.y + y.1, width: velocity.width + width.1, height: velocity.height + height.1)
        }
        return (offset, velocity)
    }

    /// `frame`, at its rest, takes what the springs show at the layer's local `time` and their velocity.
    func adopt(into frame: inout AnimatedFrame, at time: CFTimeInterval) {
        let (offset, velocity) = shown(at: time)
        frame.x.value = frame.x.target + offset.x
        frame.x.velocity = velocity.x
        frame.y.value = frame.y.target + offset.y
        frame.y.velocity = velocity.y
        frame.width.value = frame.width.target + offset.width
        frame.width.velocity = velocity.width
        frame.height.value = frame.height.target + offset.height
        frame.height.velocity = velocity.height
    }
}
