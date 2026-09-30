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

    /// Advances by `dt` seconds using fixed substeps (semi-implicit Euler),
    /// stable for every frame rate up to 120 Hz and beyond. `dt` is capped
    /// at 0.1 s so a stalled frame never teleports.
    public mutating func step(_ dt: Double, parameters: SpringParameters) {
        let stiffness = parameters.stiffness
        let damping = parameters.damping
        var remaining = min(max(dt, 0), 0.1)
        let maxStep = 1.0 / 480.0
        var x = Double(value)
        var v = Double(velocity)
        let t = Double(target)
        while remaining > 0 {
            let h = min(remaining, maxStep)
            let acceleration = -stiffness * (x - t) - damping * v
            v += acceleration * h
            x += v * h
            remaining -= h
        }
        value = CGFloat(x)
        velocity = CGFloat(v)
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

    /// Steps and snaps once settled. Returns true while still moving.
    public mutating func advance(_ dt: Double, parameters: SpringParameters, epsilon: CGFloat) -> Bool {
        guard value != target || velocity != 0 else { return false }
        step(dt, parameters: parameters)
        if isSettled(epsilon: epsilon) {
            snap()
            return false
        }
        return true
    }
}
