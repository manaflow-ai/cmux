import Foundation

/// A damped spring in UIKit's parametrisation: mass 1, stiffness
/// (2 pi / duration)^2, damping 4 pi (1 - bounce) / duration for bounce >= 0,
/// and 4 pi / (duration (1 + bounce)) below zero, as SwiftUI and UIKit define it.
struct Spring: Hashable, Sendable {
    var duration: Double
    var bounce: Double
    var initialVelocity: Double = 0

    var mass: Double { 1 }
    var stiffness: Double { pow(2 * .pi / duration, 2) }
    var damping: Double { bounce >= 0 ? 4 * .pi * (1 - bounce) / duration : 4 * .pi / (duration * (1 + bounce)) }

    /// Progress 0 -> 1 at `tau` seconds after the start (closed form).
    func progress(_ tau: Double) -> Double {
        Spring.progress(tau, mass: mass, stiffness: stiffness, damping: damping, velocity: initialVelocity)
    }

    /// Closed form of a mass-spring-damper from 0 to 1, as CASpringAnimation
    /// runs it (initial velocity in units of the full distance per second).
    static func progress(_ tau: Double, mass m: Double, stiffness k: Double, damping c: Double, velocity v0: Double) -> Double {
        guard tau > 0 else { return 0 }
        let w0 = (k / m).squareRoot()
        let zeta = c / (2 * (k * m).squareRoot())
        let x0 = -1.0
        let x: Double
        if zeta < 1 - 1e-9 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            x = exp(-zeta * w0 * tau) * (x0 * cos(wd * tau) + (v0 + zeta * w0 * x0) / wd * sin(wd * tau))
        } else if zeta <= 1 + 1e-9 {
            x = exp(-w0 * tau) * (x0 + (v0 + w0 * x0) * tau)
        } else {
            let s = (zeta * zeta - 1).squareRoot()
            let r1 = -w0 * (zeta - s), r2 = -w0 * (zeta + s)
            let c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2
            x = c1 * exp(r1 * tau) + c2 * exp(r2 * tau)
        }
        return 1 + x
    }

    /// Time after which the motion stays within `epsilon` of the distance:
    /// walks back from a safe bound to the last time the error exceeds it.
    func settlingTime(epsilon: Double = 2e-4) -> Double {
        let step = 1.0 / 240
        var t = 4.0
        while t > 0, abs(1 - progress(t)) < epsilon { t -= step }
        return min(4, t + step)
    }

    /// The same spring with every time constant multiplied by `factor`.
    func scaled(_ factor: Double) -> Spring {
        Spring(duration: duration * factor, bounce: bounce, initialVelocity: initialVelocity / factor)
    }
}

/// One fitted element: `from + sum_i delta_i * spring_i(t - delay_i)`. A move
/// distributes its distance by each component's share of the fitted deltas;
/// a pulse (`from == to`) keeps the fitted deltas as absolute amounts.
struct SpringElement: Hashable, Sendable {
    struct Component: Hashable, Sendable {
        var delay: Double
        var spring: Spring
        var delta: Double
        /// `spring.settlingTime()`, computed once (it costs up to 960 evaluations).
        let settle: Double

        init(delay: Double, spring: Spring, delta: Double) {
            self.delay = delay
            self.spring = spring
            self.delta = delta
            settle = spring.settlingTime()
        }
    }

    var name: String
    var from: Double
    var to: Double
    var components: [Component]

    var isPulse: Bool { abs(to - from) < 1e-6 }

    func share(_ i: Int) -> Double {
        let total = components.reduce(0) { $0 + $1.delta }
        return abs(total) < 1e-9 ? 0 : components[i].delta / total
    }

    /// Value at `tau` after the event for a move from `a` to `b` (a pulse: `a`
    /// plus the fitted deltas).
    func value(_ tau: Double, from a: Double, to b: Double) -> Double {
        var v = a
        for (i, c) in components.enumerated() {
            let d = isPulse ? c.delta : (b - a) * share(i)
            v += d * c.spring.progress(tau - c.delay)
        }
        return v
    }

    /// When the last component is within its settle tolerance.
    var settleTime: Double { components.map { $0.delay + $0.settle }.max() ?? 0 }

    /// Every delay and spring time constant multiplied by `factor`
    /// (`ui.animationSpeed = normal` is 1.5, motion.md rule 8).
    func scaled(_ factor: Double) -> SpringElement {
        guard factor != 1 else { return self }
        var copy = self
        copy.components = components.map { Component(delay: $0.delay * factor, spring: $0.spring.scaled(factor), delta: $0.delta) }
        return copy
    }
}
