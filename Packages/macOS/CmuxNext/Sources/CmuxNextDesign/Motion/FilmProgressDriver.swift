#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation
public import QuartzCore

/// Film-only (ZOOM VARIANTS Z4, cmux-ad m66; CLOSE VARIANTS 2 V6, m67; DEBUG and bench builds only, never merged): ONE
/// progress value of a curve drives several layer properties at once, a frame and an opacity, so they move together
/// ("the rest of it fade, in the same easing function"). A bezier curve: one Core Animation timing per property, all the
/// same. A spring (damping ratio, response; mass 1, stiffness (2 pi / response)^2, damping 4 pi ratio / response): its
/// step response sampled every 1/240 s until it rests within 0.5 pt of 900 pt, as key frames, so each property's value
/// at every sample is `value(p)` of the same p, and a property that must not overshoot clamps it there (an opacity).
public struct FilmProgressDriver: Sendable, Equatable {
    public enum Curve: Sendable, Equatable {
        case bezier(x1: Float, y1: Float, x2: Float, y2: Float, seconds: Double)
        case spring(damping: Double, response: Double)
    }

    public var curve: Curve

    public init(points: (Float, Float, Float, Float), seconds: Double) {
        curve = .bezier(x1: points.0, y1: points.1, x2: points.2, y2: points.3, seconds: seconds)
    }

    public init(damping: Double, response: Double) { curve = .spring(damping: damping, response: response) }

    /// Seconds until rest: a bezier's duration, a spring's settle time to 0.5 pt over 900 pt.
    public var duration: TimeInterval {
        switch curve {
        case let .bezier(_, _, _, _, seconds): seconds
        case .spring: progress()?.duration ?? 0
        }
    }

    /// A spring's progress (0 at the start, 1 at rest, past 1 on its overshoot) every 1/240 s, the last sample exactly
    /// 1 at the settle time, with key times 0 ... 1. Nil for a bezier curve.
    public func progress() -> (times: [NSNumber], values: [Double], duration: Double)? {
        guard case let .spring(ratio, response) = curve, response > 0 else { return nil }
        let omega = 2 * Double.pi / response
        let stiffness = omega * omega, damping = 2 * ratio * omega
        let dt = 0.0005, every = 1.0 / 240, within = 0.5 / 900
        var x = 1.0, v = 0.0, t = 0.0, settle = 0.0
        var samples: [(Double, Double)] = [(0, 0)]
        var next = every
        while t < 2 {
            let a = -stiffness * x - damping * v
            v += a * dt
            x += v * dt
            t += dt
            if abs(x) > within { settle = t }
            if t >= next { samples.append((t, 1 - x)); next += every }
        }
        let end = max(settle, 1.0 / 120)
        samples = samples.filter { $0.0 < end } + [(end, 1)]
        return (samples.map { NSNumber(value: $0.0 / end) }, samples.map(\.1), end)
    }

    /// `layer.keyPath` driven by the curve's progress: `value(p)` for each p (clamp inside `value` where the property
    /// must not overshoot). Every property driven this way in one turn moves on the same p at the same instant. Through
    /// the pane motion gate (`Motion.panes`): with its movement off, `value(1)` applies at once. `completion` runs at
    /// rest (at once with no animation).
    @MainActor public func drive(_ layer: CALayer, _ keyPath: String, _ value: (Double) -> Any,
                                 completion: @escaping @MainActor () -> Void) {
        guard Motion.panes.animatesMovement, duration > 0 else {
            Motion.setModel(layer, keyPath, value(1))
            completion()
            return
        }
        CATransaction.begin()
        defer { CATransaction.commit() }
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } } // main-proof: CATransaction.h: the completion block is called on the main thread
        Motion.setModel(layer, keyPath, value(1))
        let animation: CAAnimation
        switch curve {
        case let .bezier(x1, y1, x2, y2, seconds):
            let basic = CABasicAnimation(keyPath: keyPath)
            basic.timingFunction = CAMediaTimingFunction(controlPoints: x1, y1, x2, y2)
            basic.duration = seconds
            basic.fromValue = value(0)
            basic.toValue = value(1)
            animation = basic
        case .spring:
            guard let progress = progress() else { return }
            let frames = CAKeyframeAnimation(keyPath: keyPath)
            frames.values = progress.values.map(value)
            frames.keyTimes = progress.times
            frames.calculationMode = .linear
            frames.duration = progress.duration
            animation = frames
        }
        Motion.add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).film-progress")
    }
}

#endif
