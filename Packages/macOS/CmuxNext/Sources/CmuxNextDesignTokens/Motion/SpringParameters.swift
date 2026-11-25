public import CoreGraphics
public import Foundation

/// Spring tuning in SwiftUI terms, with the equivalent Core Animation
/// constants (mass 1).
public nonisolated struct SpringParameters: Hashable, Sendable {
    /// Seconds for one undamped oscillation; smaller is stiffer.
    public var response: Double
    /// 1 is critically damped; above 1 is slower. Below 1 passes the target: no Motion token is
    /// (`MotionSpring.base`).
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

    /// The velocity a value may start a step with, `distance` (its target minus its value) from its
    /// target: no motion passes its target (Lawrence 2026-11-10; motion-first-principles-DESIGN.md,
    /// principle 5). A velocity carries only when it points at the target, and then at most
    /// omega x |distance|; one that points away, or one at the target, is dropped.
    ///
    /// Why omega x |distance|: with x = value - target, a critically damped spring is
    /// x(t) = (x0 + (v0 + omega x0) t) e^(-omega t). It is zero at t = -x0 / (v0 + omega x0), which is
    /// a time to come only when v0 points at the target and |v0| > omega |x0|. So a velocity toward
    /// the target of at most omega |x0| never reaches zero: the value arrives and does not pass.
    /// Over-damped, the limit is omega (zeta + sqrt(zeta^2 - 1)) |x0|, which is larger, so
    /// omega |x0| is safe there too. Along a free path the ratio r = v / |x| obeys
    /// r' = omega^2 - 2 zeta omega r + r^2, which is not positive between its roots, so a path that
    /// starts under the limit stays under it: the limit changes a state only when a caller wrote one
    /// (a release velocity, a new target under a moving value), never a spring in free flight.
    public func admitted(velocity: CGFloat, distance: CGFloat) -> CGFloat {
        guard velocity != 0 else { return 0 }
        let limit = CGFloat(omega) * abs(distance)
        if distance > 0 { return min(max(velocity, 0), limit) }
        if distance < 0 { return max(min(velocity, 0), -limit) }
        return 0
    }

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
}
