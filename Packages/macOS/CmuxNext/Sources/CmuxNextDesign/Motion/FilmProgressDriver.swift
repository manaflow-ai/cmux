#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation
public import QuartzCore

/// Film-only (ZOOM VARIANTS Z4, cmux-ad m66; CLOSE VARIANTS 2 V6, m67; DEBUG and bench builds only, never merged): ONE
/// progress value of a curve drives several layer properties at once, a frame and an opacity, so they move together
/// ("the rest of it fade, in the same easing function"). A bezier curve: one Core Animation timing per property, all the
/// same. A spring (damping ratio, response; mass 1, stiffness (2 pi / response)^2, damping 4 pi ratio / response): its
/// exact step response sampled every 1/240 s until it rests within 0.5 pt of 900 pt, as key frames, so each property's value
/// at every sample is `value(p)` of the same p, and a property that must not overshoot clamps it there (an opacity).
public struct FilmProgressDriver: Sendable, Equatable {
    public enum Curve: Sendable, Equatable {
        case bezier(x1: Float, y1: Float, x2: Float, y2: Float, seconds: Double)
        case spring(damping: Double, response: Double)
    }

    public let curve: Curve
    /// A spring's progress table (``progress()``), computed once when the driver is made: a key turn makes one driver and
    /// drives every layer of the zoom with it (frame, mask, each pane's opacity), so the 4000-step settle search runs once
    /// per key, not twice per driven layer (ZOOM VARIANTS 3, key-turn profile item 1: 2.0 + 1.1 ms per press).
    private let table: SpringTable?

    private struct SpringTable: Sendable, Equatable { let times: [Double], values: [Double], duration: Double }

    public init(points: (Float, Float, Float, Float), seconds: Double) {
        curve = .bezier(x1: points.0, y1: points.1, x2: points.2, y2: points.3, seconds: seconds)
        table = nil
    }

    public init(damping: Double, response: Double) {
        curve = .spring(damping: damping, response: response)
        table = Self.springTable(curve)
    }

    /// Seconds until rest: a bezier's duration, a spring's settle time to 0.5 pt over 900 pt.
    public var duration: TimeInterval {
        switch curve {
        case let .bezier(_, _, _, _, seconds): seconds
        case .spring: table?.duration ?? 0
        }
    }

    /// A spring's progress (0 at the start, 1 at rest, past 1 only on an under-damped overshoot) every 1/240 s, the last
    /// sample exactly 1 at the settle time, with key times 0 ... 1. Nil for a bezier curve. The exact step response (no
    /// numeric integration), so a critically damped spring (ratio 1, m68 "no bounce") never passes 1.
    public func progress() -> (times: [NSNumber], values: [Double], duration: Double)? {
        guard let table else { return nil }
        return (table.times.map { NSNumber(value: $0) }, table.values, table.duration)
    }

    private static func springTable(_ curve: Curve) -> SpringTable? {
        guard case .spring = curve else { return nil }
        let probe = FilmProgressDriver(probing: curve)
        let every = 1.0 / 240, within = 0.5 / 900
        var settle = 0.0, t = 0.0
        while t < 2 {
            t += 0.0005
            if let p = probe.step(t), abs(1 - p) > within { settle = t }
        }
        let end = max(settle, 1.0 / 120)
        var samples: [(Double, Double)] = [(0, 0)]
        var at = every
        while at < end {
            samples.append((at, probe.step(at) ?? 1))
            at += every
        }
        samples.append((end, 1))
        return SpringTable(times: samples.map { $0.0 / end }, values: samples.map(\.1), duration: end)
    }

    /// The curve alone, no table (``step(_:)`` for the table's own search).
    private init(probing curve: Curve) {
        self.curve = curve
        table = nil
    }

    /// The spring's step response at `t` s (0 at rest at the start, 1 at the target), from rest. Nil for a bezier curve.
    public func step(_ t: Double) -> Double? {
        guard case let .spring(ratio, response) = curve, response > 0 else { return nil }
        let omega = 2 * Double.pi / response
        if abs(ratio - 1) < 1e-9 { return 1 - (1 + omega * t) * exp(-omega * t) }
        if ratio < 1 {
            let wd = omega * (1 - ratio * ratio).squareRoot()
            return 1 - exp(-ratio * omega * t) * (cos(wd * t) + ratio * omega / wd * sin(wd * t))
        }
        let root = (ratio * ratio - 1).squareRoot()
        let r1 = -omega * (ratio - root), r2 = -omega * (ratio + root)
        return 1 - (r2 * exp(r1 * t) - r1 * exp(r2 * t)) / (r2 - r1)
    }

    /// The largest progress past 1 (0: no overshoot), times the travel gives the overshoot in points.
    public var overshoot: Double { max(0, (table?.values.max() ?? 1) - 1) }

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
