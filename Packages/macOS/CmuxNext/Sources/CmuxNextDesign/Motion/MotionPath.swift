public import QuartzCore

/// Where a layer's animated geometry is at any media time: its model value plus every animation on it,
/// evaluated the way the render server does (perf I7). A change that must follow a moving layer
/// exactly (a cell's inner parts riding its growing bounds, a mask under a pill that crosses it) reads
/// the path once and adds its own keyframes from now to the path's end, so nothing steps on the main
/// thread per frame and a move that starts over a running one is exact: the path is the sum of every
/// move in flight, each on its own curve. Supported: basic and spring animations (additive or not) and
/// linear or discrete keyframes, on `position`, `bounds.size` and their components; any other
/// animation on the key path makes `isExact` false.
public struct MotionPath {
    /// One animation of the path, its times in media time, decoded once: `value(at:)` runs per sample
    /// (a tab strip samples every cell at 120 Hz along every move in flight on each switch), so it reads
    /// no Core Animation property, value type name or key path string.
    struct Segment {
        let begin: CFTimeInterval
        let speed: Double
        let duration: CFTimeInterval
        /// The value holds after the animation ends (`fillMode` forwards or both).
        let holds: Bool
        let component: Component
        let additive: Bool
        /// nil: a value type the path cannot read (the segment adds nothing, as before).
        let curve: Curve?

        var end: CFTimeInterval { begin + duration / max(speed, .ulpOfOne) }
    }

    /// An animation's values and timing, as (x, y); a scalar is in x.
    enum Curve {
        case spring(from: CGPoint, to: CGPoint, Spring)
        case basic(from: CGPoint, to: CGPoint, Ease?)
        case keyframes(values: [CGPoint], times: [CGFloat], discrete: Bool, Ease?)
    }

    /// A spring's constants, read once from its `CASpringAnimation`.
    struct Spring {
        let mass: Double
        let stiffness: Double
        let damping: Double
        let velocity: Double
    }

    /// A timing function's control points, read once.
    struct Ease {
        let x1: Double, y1: Double, x2: Double, y2: Double

        init(_ function: CAMediaTimingFunction) {
            var p1 = [Float](repeating: 0, count: 2), p2 = [Float](repeating: 0, count: 2)
            function.getControlPoint(at: 1, values: &p1)
            function.getControlPoint(at: 2, values: &p2)
            (x1, y1, x2, y2) = (Double(p1[0]), Double(p1[1]), Double(p2[0]), Double(p2[1]))
        }
    }

    /// The model value (x, y, or width, height).
    public let model: CGPoint
    private var segments: [Segment] = []
    /// Every animation on the key path is one this type evaluates.
    public private(set) var isExact = true

    /// The path of `keyPath` ("position" or "bounds.size") on `layer`. `now`: the media time an animation
    /// added in the open transaction (begin time 0) starts at.
    public init(_ layer: CALayer, _ keyPath: String, now: CFTimeInterval = CACurrentMediaTime()) {
        self.init(layer, keyPath, now: now, kindOf: ValueKind.init(of:))
    }

    /// - Parameter kindOf: Reads an animation value's kind; called once per animation value list (tests count it).
    init(_ layer: CALayer, _ keyPath: String, now: CFTimeInterval, kindOf: (Any?) -> ValueKind?) {
        switch keyPath {
        case "bounds.size": model = CGPoint(x: layer.bounds.width, y: layer.bounds.height)
        default: model = layer.position
        }
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) else { continue }
            let path = (animation as? CAPropertyAnimation)?.keyPath ?? ""
            guard path == keyPath || path.hasPrefix(keyPath + ".") else { continue }
            guard animation is CABasicAnimation || animation is CAKeyframeAnimation else {
                isExact = false
                continue
            }
            let begin = animation.beginTime > 0 ? layer.convertTime(animation.beginTime, to: nil) : now
            let duration = (animation as? CASpringAnimation).map { $0.duration > 0 ? $0.duration : $0.settlingDuration } ?? animation.duration
            let property = animation as? CAPropertyAnimation
            segments.append(Segment(begin: begin - animation.timeOffset / Double(max(animation.speed, .ulpOfOne)),
                                    speed: Double(animation.speed), duration: duration,
                                    holds: animation.fillMode == .forwards || animation.fillMode == .both,
                                    component: Self.component(of: property?.keyPath ?? keyPath, under: keyPath),
                                    additive: property?.isAdditive ?? false, curve: Self.curve(animation, kindOf: kindOf)))
        }
    }

    /// The latest media time an animation of the path ends; nil when nothing moves it.
    public var end: CFTimeInterval? { segments.map(\.end).max() }

    /// Whether anything moves the path after `time`.
    public func moves(after time: CFTimeInterval) -> Bool { (end ?? -.infinity) > time }

    /// The value the render server shows at media time `time`.
    public func value(at time: CFTimeInterval) -> CGPoint { // perf-hot: 0.01ms tab-switch (per cell, per sample)
        var value = model
        for segment in segments {
            let local = (time - segment.begin) * segment.speed
            guard local >= 0, local < segment.duration || segment.holds, let curve = segment.curve else { continue }
            let shown = Self.sample(curve, local: min(local, segment.duration), duration: segment.duration)
            let additive = segment.additive
            switch segment.component {
            case .x: value.x = additive ? value.x + shown.x : shown.x
            case .y: value.y = additive ? value.y + shown.x : shown.x
            case .both:
                value.x = additive ? value.x + shown.x : shown.x
                value.y = additive ? value.y + shown.y : shown.y
            }
        }
        return value
    }

    /// `count + 1` media times from `start` to `end`, evenly spaced (`count` at least 1).
    public static func times(from start: CFTimeInterval, to end: CFTimeInterval, count: Int) -> [CFTimeInterval] {
        let count = max(1, count)
        return (0...count).map { start + (end - start) * Double($0) / Double(count) }
    }

    /// Samples for a path that runs `seconds`: one per frame of the fastest display.
    public static func sampleCount(seconds: CFTimeInterval, framesPerSecond: Double = 120) -> Int {
        max(1, Int((seconds * framesPerSecond).rounded(.up)))
    }

    /// A keyframe animation of `values` at `times` (from `times[0]`, which is now, to the last), in
    /// `layer`'s time: linear between frames (`discrete`: each value holds until the next time). Pairs
    /// with `MotionPath` samples so a dependent layer follows a moving one frame by frame. `steps`: the
    /// indices i after which the value jumps instead of moving (a layout that changes form between
    /// samples i and i + 1 holds value i until time i + 1, as a discrete value does).
    public static func keyframes(_ keyPath: String, values: [Any], times: [CFTimeInterval], on layer: CALayer, discrete: Bool = false,
                                 steps: Set<Int> = []) -> CAKeyframeAnimation? {
        guard values.count == times.count, values.count > 1, let first = times.first, let last = times.last, last > first else { return nil }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        let span = last - first
        let keyTimes = times.map { NSNumber(value: ($0 - first) / span) }
        if !discrete, !steps.isEmpty {
            var stepped: [Any] = [], stepTimes: [NSNumber] = []
            for index in values.indices {
                stepped.append(values[index])
                stepTimes.append(keyTimes[index])
                if steps.contains(index), index + 1 < values.count {
                    stepped.append(values[index])
                    stepTimes.append(keyTimes[index + 1])
                }
            }
            animation.values = stepped
            animation.calculationMode = .linear
            animation.keyTimes = stepTimes
            animation.beginTime = layer.convertTime(first, from: nil)
            animation.duration = span
            return animation
        }
        if discrete {
            // One more key time than values: value i holds from time i to time i + 1; the model shows after.
            animation.values = Array(values.dropLast())
            animation.calculationMode = .discrete
        } else {
            animation.values = values
            animation.calculationMode = .linear
        }
        animation.keyTimes = keyTimes
        animation.beginTime = layer.convertTime(first, from: nil)
        animation.duration = span
        return animation
    }

    // MARK: - Evaluation

    enum Component { case x, y, both }

    private static func component(of path: String, under keyPath: String) -> Component {
        switch path.dropFirst(keyPath.count) {
        case ".x", ".width": .x
        case ".y", ".height": .y
        default: .both
        }
    }

    /// What `animation` moves, decoded once; nil for a value type the path cannot read. The value kind
    /// (point, size or number) is read once per value list, from its first value, not per value.
    private static func curve(_ animation: CAAnimation, kindOf: (Any?) -> ValueKind?) -> Curve? {
        if let spring = animation as? CASpringAnimation {
            guard let kind = kindOf(spring.fromValue), let from = kind.point(spring.fromValue), let to = kind.point(spring.toValue) else { return nil }
            return .spring(from: from, to: to, Spring(mass: Double(max(spring.mass, .ulpOfOne)), stiffness: Double(spring.stiffness),
                                                      damping: Double(spring.damping), velocity: Double(spring.initialVelocity)))
        }
        if let basic = animation as? CABasicAnimation {
            guard let kind = kindOf(basic.fromValue), let from = kind.point(basic.fromValue), let to = kind.point(basic.toValue) else { return nil }
            return .basic(from: from, to: to, basic.timingFunction.map(Ease.init))
        }
        guard let keyframes = animation as? CAKeyframeAnimation, let raw = keyframes.values, let kind = kindOf(raw.first) else { return nil }
        let values = raw.compactMap(kind.point)
        guard !values.isEmpty else { return nil }
        let discrete = keyframes.calculationMode == .discrete
        let times = keyframes.keyTimes?.map { CGFloat($0.doubleValue) }
            ?? (0..<(discrete ? values.count + 1 : values.count)).map { CGFloat($0) / CGFloat(max(1, (discrete ? values.count : values.count - 1))) }
        return .keyframes(values: values, times: times, discrete: discrete, keyframes.timingFunction.map(Ease.init))
    }

    /// The curve's value at local time `local` (seconds into it), as (x, y); a scalar is in x.
    private static func sample(_ curve: Curve, local: CFTimeInterval, duration: CFTimeInterval) -> CGPoint {
        switch curve {
        case let .spring(from, to, spring):
            let progress = springProgress(spring, at: local)
            return CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
        case let .basic(from, to, function):
            let progress = ease(function, duration > 0 ? local / duration : 1)
            return CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
        case let .keyframes(values, times, discrete, function):
            let progress = ease(function, duration > 0 ? local / duration : 1)
            guard let next = times.firstIndex(where: { $0 > progress }) else { return values[values.count - 1] }
            let index = max(0, next - 1)
            if discrete { return values[min(index, values.count - 1)] }
            guard index + 1 < values.count else { return values[values.count - 1] }
            let span = times[index + 1] - times[index]
            let t = span > 0 ? (progress - times[index]) / span : 1
            let a = values[index], b = values[index + 1]
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// The timing function's progress at linear time `t` in [0, 1] (nil: linear).
    static func ease(_ function: Ease?, _ t: Double) -> CGFloat {
        let t = min(max(t, 0), 1)
        guard let function else { return CGFloat(t) }
        let (x1, y1, x2, y2) = (function.x1, function.y1, function.x2, function.y2)
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        // Solve x(s) = t by bisection (x is monotonic for a timing function), then read y(s).
        var low = 0.0, high = 1.0, s = t
        for _ in 0..<40 {
            let x = bezier(s, x1, x2)
            if abs(x - t) < 1e-7 { break }
            if x < t { low = s } else { high = s }
            s = (low + high) / 2
        }
        return CGFloat(bezier(s, y1, y2))
    }

    /// A spring's progress from its from value (0) to its to value (1) at `time` seconds: the damped
    /// harmonic oscillator Core Animation runs (`initialVelocity` in units of the whole travel).
    static func springProgress(_ spring: Spring, at time: CFTimeInterval) -> CGFloat {
        let mass = spring.mass, stiffness = spring.stiffness, damping = spring.damping
        let omega = (stiffness / mass).squareRoot()
        let zeta = damping / (2 * (stiffness * mass).squareRoot())
        let velocity = spring.velocity
        let t = max(0, time)
        // d: the travel left (1 at the start), with d'(0) = -velocity.
        let left: Double
        if zeta < 1 {
            let damped = omega * (1 - zeta * zeta).squareRoot()
            left = exp(-zeta * omega * t) * (cos(damped * t) + (zeta * omega - velocity) / damped * sin(damped * t))
        } else if zeta == 1 {
            left = exp(-omega * t) * (1 + (omega - velocity) * t)
        } else {
            let root = (zeta * zeta - 1).squareRoot()
            let r1 = -omega * (zeta - root), r2 = -omega * (zeta + root)
            let a = (-velocity - r2) / (r1 - r2)
            left = a * exp(r1 * t) + (1 - a) * exp(r2 * t)
        }
        return CGFloat(1 - left)
    }
}
