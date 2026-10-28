package import CCmuxMotionFFI
public import CoreGraphics
public import Foundation

/// Spring tuning in SwiftUI terms, with the equivalent Core Animation
/// constants (mass 1).
public nonisolated struct SpringParameters: Hashable, Sendable {
    /// Seconds for one undamped oscillation; smaller is stiffer.
    public var response: Double
    /// 1 is critically damped; below 1 overshoots.
    public var dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }

    /// SwiftUI `Spring(duration:bounce:)`: `duration` is the perceptual
    /// duration (the response), `bounce` 0 is critically damped, above 0
    /// overshoots (0.15 is a subtle bounce), below 0 is over-damped.
    public init(duration: Double, bounce: Double) {
        self.response = duration
        self.dampingFraction = bounce >= 0 ? 1 - bounce : 1 / (1 + bounce)
    }

    /// SwiftUI's bounce for this damping fraction (0 critically damped).
    public var bounce: Double {
        dampingFraction <= 1 ? 1 - dampingFraction : 1 / dampingFraction - 1
    }

    /// The same response with `bounce` (SwiftUI semantics).
    public func withBounce(_ bounce: Double) -> SpringParameters {
        SpringParameters(duration: response, bounce: bounce)
    }

    /// Angular frequency (rad/s).
    public var omega: Double { 2 * .pi / max(response, 0.001) }
    /// `CASpringAnimation.stiffness` for mass 1.
    public var stiffness: Double { omega * omega }
    /// `CASpringAnimation.damping` for mass 1.
    public var damping: Double { 2 * dampingFraction * omega }

    /// The same spring with every time constant multiplied by `scale`.
    public func scaled(by scale: Double) -> SpringParameters {
        SpringParameters(response: response * scale, dampingFraction: dampingFraction)
    }

    /// Seconds until a unit step stays within `fraction` of its target
    /// (envelope bound; exact for critical damping up to rounding).
    public func settlingTime(within fraction: Double = 0.01) -> Double {
        let zeta = min(max(dampingFraction, 0.05), 1)
        if zeta >= 0.999 {
            // Critically damped: (1 + wt) e^{-wt} = fraction, solved by fixed point.
            var x = 1.0
            for _ in 0..<32 { x = log((1 + x) / fraction) }
            return x / omega
        }
        return -log(fraction * sqrt(1 - zeta * zeta)) / (zeta * omega)
    }

    /// Seconds until a step stays within 0.5% of its target: the last
    /// visible pixel of a 200 pt move, which is what a viewer reads as the
    /// animation's length. Simulated (the envelope bound overestimates
    /// under-damped springs). Used to give timed APIs (window frames) an
    /// equivalent ease-out duration, and by the token tests.
    public var perceivedDuration: Double {
        var value = SpringValue(0)
        value.target = 1
        let step = 1.0 / 480.0
        var elapsed = 0.0
        var lastOutside = 0.0
        while elapsed < 3 {
            value.step(step, parameters: self)
            elapsed += step
            if abs(1 - value.value) > 0.005 { lastOutside = elapsed }
            if elapsed > lastOutside + 0.25 { break }
        }
        return lastOutside
    }
}

/// One scalar driven by a damped spring toward `target`. Retargeting keeps
/// `value` and `velocity`, so an interrupted animation continues from where
/// it is on screen with its momentum: no jump, no queue.
public nonisolated struct SpringValue: Hashable, Sendable {
    public var value: CGFloat
    public var velocity: CGFloat = 0
    public var target: CGFloat

    public init(_ value: CGFloat) {
        self.value = value
        self.target = value
    }

    /// Advances by `dt` seconds with the closed-form solution of the damped
    /// harmonic oscillator (under-, critically or over-damped), so the path
    /// is exact and identical at every frame rate: two 60 Hz frames land
    /// where four 120 Hz frames do. `dt` is capped at 0.1 s so a stalled
    /// frame never teleports. The solution is cmux-motion's, through the app
    /// FFI (`cmux_motion_step`, no settle: epsilon 0); a non-finite or
    /// non-positive tuning takes `move`'s (cmux-motion `finite_or`).
    public mutating func step(_ dt: Double, parameters: SpringParameters) {
        _ = stepFFI(dt, parameters: parameters, epsilon: 0)
    }

    /// Displacement from the target and velocity `time` seconds after a state, for `parameters`
    /// (mass 1), from cmux-motion's closed form (`cmux_motion_step` with no settle). The FFI caps one
    /// step at 0.1 s, so a time is solved in exact 0.1 s pieces (the solution composes), at most 100:
    /// at or past the settle horizon, min(10 s, 20 x response), and for a non-finite time, the spring
    /// is at rest. A non-finite or non-positive tuning takes `move`'s, as cmux-motion `finite_or` does,
    /// so an undamped spring settles too. (ColorTransition is the only caller; it moves to
    /// cmux_motion_spring_progress_monotone, after which this goes.)
    public static func solve(displacement x0: Double, velocity v0: Double, time t: Double,
                             parameters: SpringParameters) -> (displacement: Double, velocity: Double) {
        let fallback = MotionSpring.move.base
        let response = parameters.response.isFinite && parameters.response > 0 ? parameters.response : fallback.response
        let damping = parameters.dampingFraction.isFinite && parameters.dampingFraction > 0 ? parameters.dampingFraction : fallback.dampingFraction
        guard t.isFinite, t < min(10, 20 * response) else { return (0, 0) }
        var state = CmuxMotionState(value: x0, velocity: v0, target: 0)
        let spring = CmuxMotionSpring(response: response, damping_fraction: damping)
        var left = max(t, 0)
        while left > 0 {
            let dt = min(left, 0.1)
            _ = cmux_motion_step(&state, dt, spring, 0)
            left -= dt
        }
        return (state.value, state.velocity)
    }

    /// One `cmux_motion_step` call on this value: steps, and snaps once
    /// within `epsilon` and slower than 8 x `epsilon` per second.
    private mutating func stepFFI(_ dt: Double, parameters: SpringParameters, epsilon: CGFloat) -> Bool {
        var state = CmuxMotionState(value: Double(value), velocity: Double(velocity), target: Double(target))
        let spring = CmuxMotionSpring(response: parameters.response, damping_fraction: parameters.dampingFraction)
        let moving = cmux_motion_step(&state, dt, spring, Double(epsilon))
        value = CGFloat(state.value)
        velocity = CGFloat(state.velocity)
        return moving
    }

    public func isSettled(epsilon: CGFloat) -> Bool {
        abs(value - target) < epsilon && abs(velocity) < epsilon * 8
    }

    /// Jumps to the target and stops.
    public mutating func snap() {
        value = target
        velocity = 0
    }

    /// Sets a new target and stops there at once.
    public mutating func snap(to target: CGFloat) {
        self.target = target
        snap()
    }

    /// Steps and snaps once settled (cmux-motion `advance_spring`). Returns
    /// true while still moving.
    public mutating func advance(_ dt: Double, parameters: SpringParameters, epsilon: CGFloat) -> Bool {
        stepFFI(dt, parameters: parameters, epsilon: epsilon)
    }
}
