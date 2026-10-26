import CmuxNextDesign
import CoreGraphics
import Foundation
import QuartzCore

/// How far one spring's value goes from its rest on its whole way (points, below and above the rest).
nonisolated struct Excursion: Equatable, Sendable {
    var low: CGFloat = 0
    var high: CGFloat = 0

    static let zero = Excursion()

    /// The excursion of what a camera carries: a camera moving content by d moves it by -d in the view.
    var negated: Excursion { Excursion(low: -high, high: -low) }

    /// Two springs that move one value at once: their sum reaches no further than the sum of their bounds.
    mutating func add(_ other: Excursion) {
        low += other.low
        high += other.high
    }
}

extension SpringParameters {
    /// How far `value` goes from its target on its whole way on this spring (``excursion(displacement:velocity:)``).
    nonisolated func excursion(of value: SpringValue) -> Excursion {
        excursion(displacement: value.value - value.target, velocity: value.velocity)
    }

    /// The lowest and highest displacement from the target of a spring that starts `displacement` away moving at
    /// `velocity` (mass 1, the closed form `SpringValue.solve` steps, with its fallback for a non-finite or
    /// non-positive tuning): the start, the rest, and the turning points where the velocity is zero. Velocity and
    /// bounce carry a spring past its rest; after the first two turning points of a bounce each swing is smaller,
    /// so these bound the whole way.
    nonisolated func excursion(displacement: CGFloat, velocity: CGFloat) -> Excursion {
        let x0 = Double(displacement), v0 = Double(velocity)
        guard x0.isFinite, v0.isFinite, x0 != 0 || v0 != 0 else { return .zero }
        var low = min(0, x0), high = max(0, x0)
        func include(_ x: Double) {
            guard x.isFinite else { return }
            low = min(low, x)
            high = max(high, x)
        }
        let fallback = MotionSpring.move.base
        let response = self.response.isFinite && self.response > 0 ? self.response : fallback.response
        let zeta = dampingFraction.isFinite && dampingFraction > 0 ? dampingFraction : fallback.dampingFraction
        let omega = 2 * Double.pi / max(response, 0.001)
        if zeta < 0.9999 {
            // x(t) = e^(-d t) (x0 cos(w t) + b sin(w t)); its velocity is zero where tan(w t) = v0 / (x0 w + d b).
            let damped = omega * (1 - zeta * zeta).squareRoot(), decay = zeta * omega
            let b = (v0 + decay * x0) / damped
            var turn = atan2(v0, x0 * damped + decay * b)
            if turn <= 0 { turn += .pi }
            for phase in [turn, turn + .pi] {
                include(exp(-decay * phase / damped) * (x0 * cos(phase) + b * sin(phase)))
            }
        } else if zeta <= 1.0001 {
            // x(t) = (x0 + r t) e^(-w t), r = v0 + w x0; its velocity is zero at t = v0 / (w r).
            let rate = v0 + omega * x0
            if rate != 0 {
                let time = v0 / (omega * rate)
                if time > 0 { include((x0 + rate * time) * exp(-omega * time)) }
            }
        } else {
            // x(t) = c1 e^(s t) + c2 e^(f t); its velocity is zero where e^((s - f) t) = -c2 f / (c1 s).
            let root = (zeta * zeta - 1).squareRoot()
            let slow = -omega * (zeta - root), fast = -omega * (zeta + root)
            let c1 = (v0 - fast * x0) / (slow - fast), c2 = x0 - c1
            if c1 != 0 {
                let ratio = -(c2 * fast) / (c1 * slow)
                if ratio > 1 {
                    let time = log(ratio) / (slow - fast)
                    include(c1 * exp(slow * time) + c2 * exp(fast * time))
                }
            }
        }
        return Excursion(low: CGFloat(low), high: CGFloat(high))
    }
}

/// How far a rect's four components go from their rest on the way: every spring that moves them added up.
nonisolated struct RectExcursion: Equatable, Sendable {
    var x = Excursion.zero
    var y = Excursion.zero
    var width = Excursion.zero
    var height = Excursion.zero

    init() {}

    /// A frame's CPU spring on `spring`.
    init(_ frame: AnimatedFrame, on spring: SpringParameters) {
        x = spring.excursion(of: frame.x)
        y = spring.excursion(of: frame.y)
        width = spring.excursion(of: frame.width)
        height = spring.excursion(of: frame.height)
    }

    /// Adds each of `track`'s render-server springs that has not landed at `time`, from where it began.
    mutating func add(_ track: RenderSpringTrack, at time: CFTimeInterval) {
        for segment in track.segments where !segment.hasLanded(at: time) {
            let spring = segment.parameters
            x.add(spring.excursion(displacement: segment.offset.x, velocity: segment.velocity.x))
            y.add(spring.excursion(displacement: segment.offset.y, velocity: segment.velocity.y))
            width.add(spring.excursion(displacement: segment.offset.width, velocity: segment.velocity.width))
            height.add(spring.excursion(displacement: segment.offset.height, velocity: segment.velocity.height))
        }
    }

    /// The rect that holds every place `rest` goes on the way: its origin's reach, and its far edges' reach (origin
    /// and size together).
    func sweep(around rest: CGRect) -> CGRect {
        let minX = rest.minX + x.low, maxX = rest.maxX + x.high + width.high
        let minY = rest.minY + y.low, maxY = rest.maxY + y.high + height.high
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
