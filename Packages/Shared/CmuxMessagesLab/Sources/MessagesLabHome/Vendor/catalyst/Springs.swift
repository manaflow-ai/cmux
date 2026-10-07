#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A damped spring in UIKit's parametrisation: mass 1, stiffness
/// (2 pi / duration)^2, damping 4 pi (1 - bounce) / duration (for bounce >= 0;
/// 4 pi / (duration (1 + bounce)) below zero, as SwiftUI and UIKit define it).
struct Spring: Equatable {
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

    /// Time after which the motion stays within `epsilon` (fraction of the distance).
    private struct SettleKey: Hashable { var d, b, v, e: Double }
    private static var settleCache: [SettleKey: Double] = [:]
    private static let settleLock = NSLock()
    /// Cached: every animation commit asks for it, and the search below runs
    /// up to 960 closed-form evaluations.
    func settlingTime(epsilon: Double = 2e-4) -> Double {
        let k = SettleKey(d: duration, b: bounce, v: initialVelocity, e: epsilon)
        Spring.settleLock.lock()
        if let v = Spring.settleCache[k] { Spring.settleLock.unlock(); return v }
        Spring.settleLock.unlock()
        let v = searchSettlingTime(epsilon: epsilon)
        Spring.settleLock.lock(); Spring.settleCache[k] = v; Spring.settleLock.unlock()
        return v
    }
    private func searchSettlingTime(epsilon: Double) -> Double {
        var t = 4.0
        // Walk back from a safe bound to the last time the error exceeds epsilon.
        let step = 1.0 / 240
        while t > 0, abs(1 - progress(t)) < epsilon { t -= step }
        return min(4, t + step)
    }
}

/// A cubic timing curve, as `CAMediaTimingFunction(controlPoints:)` with a
/// fixed duration. Some transitions of the real app fit a timing curve better
/// than any spring (see TRANSITIONS.md); they are committed as additive
/// `CABasicAnimation`s, on the render server like the springs.
struct Curve: Equatable {
    var x1, y1, x2, y2: Double
    var duration: Double

    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }
    /// Progress 0 -> 1 at `tau` seconds after the start.
    func progress(_ tau: Double) -> Double {
        guard tau > 0 else { return 0 }
        guard tau < duration else { return 1 }
        return Curve.solve(tau / duration, x1, y1, x2, y2)
    }
    /// y(s) where x(s) = u for the cubic Bezier (0,0) (x1,y1) (x2,y2) (1,1).
    /// Control points are clamped to [0, 1], as Core Animation does (a fitted
    /// y2 of 1.065 overshot in the closed form but not on screen: 0.25 pt).
    static func solve(_ u: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let c = { (v: Double) in min(1, max(0, v)) }
        let x1 = c(x1), y1 = c(y1), x2 = c(x2), y2 = c(y2)
        func bx(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s }
        func by(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s }
        // x(s) is monotonic for 0 <= x1, x2 <= 1: bisection, 40 steps (2^-40).
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 { let m = (lo + hi) / 2; if bx(m) < u { lo = m } else { hi = m } }
        return by((lo + hi) / 2)
    }
}

/// One fitted element of springs.json: `from + sum_i delta_i * p_i(t - delay_i)`,
/// where each `p_i` is a spring or, when `curve` is set, a timing curve.
struct SpringElement {
    struct Component {
        var delay: Double
        var spring: Spring
        var delta: Double
        var curve: Curve? = nil
        func progress(_ tau: Double) -> Double { curve?.progress(tau) ?? spring.progress(tau) }
        var activeTime: Double { curve?.duration ?? spring.settlingTime() }
    }
    var name: String
    var from: Double
    var to: Double
    var components: [Component]
    /// For a move: each component's share of the distance. A pulse (from == to)
    /// keeps its fitted deltas.
    var isPulse: Bool { abs(to - from) < 1e-6 }
    func share(_ i: Int) -> Double {
        let total = components.reduce(0) { $0 + $1.delta }
        return abs(total) < 1e-9 ? 0 : components[i].delta / total
    }
    /// Value at `tau` after the event for a move from `a` to `b` (pulse: `a` plus the fitted deltas).
    func value(_ tau: Double, from a: Double, to b: Double) -> Double {
        var v = a
        for (i, c) in components.enumerated() {
            let d = isPulse ? c.delta : (b - a) * share(i)
            v += d * c.progress(tau - c.delay)
        }
        return v
    }
    var settleTime: Double { components.map { $0.delay + $0.activeTime }.max() ?? 0 }
}

/// springs.json, bundled. Every animated element of the app takes its timing
/// from here; nothing else defines a curve.
enum Springs {
    static let all: [String: SpringElement] = {
        // cmux: a package resource (the app's main bundle does not hold it).
        guard let url = Bundle.module.url(forResource: "springs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        var out: [String: SpringElement] = [:]
        for (name, e) in obj {
            let comps = (e["components"] as? [[String: Any]] ?? []).map { c in
                let duration = c["duration"] as? Double ?? 0.3
                let cp = c["curve"] as? [Double]
                return SpringElement.Component(delay: c["delay"] as? Double ?? 0,
                                               spring: Spring(duration: duration, bounce: c["bounce"] as? Double ?? 0,
                                                              initialVelocity: c["initialVelocity"] as? Double ?? 0),
                                               delta: c["delta"] as? Double ?? 0,
                                               curve: cp?.count == 4 ? Curve(x1: cp![0], y1: cp![1], x2: cp![2], y2: cp![3], duration: duration) : nil)
            }
            out[name] = SpringElement(name: name, from: e["from"] as? Double ?? 0, to: e["to"] as? Double ?? 0, components: comps)
        }
        return out
    }()
    static func element(_ name: String) -> SpringElement {
        all[name] ?? SpringElement(name: name, from: 0, to: 1, components: [.init(delay: 0, spring: Spring(duration: 0.3, bounce: 0), delta: 1)])
    }
    static var send: SpringElement { element("transcript.send") }
    static var delivered: SpringElement { element("transcript.delivered") }
    static var read: SpringElement { element("transcript.read") }
    static var typing: SpringElement { element("transcript.typing") }
    static var receive: SpringElement { element("transcript.receive") }
    /// A received photo or video (lossless send-typed-media take: an ease-in-out move, the
    /// photo's opacity following it).
    static var receiveMedia: SpringElement { element("transcript.receiveMedia") }
    /// My tapback (lossless tapback-menu-heart-take1: the rows above the part move 27.5 pt
    /// 90 ms after our react commit, an ease-in-out of 0.29 s).
    static var tapback: SpringElement { element("transcript.tapback") }
    static func isMedia(_ p: Part) -> Bool {
        if case let .attachment(a) = p { return a.kind == "image" || a.kind == "video" }
        return false
    }
    /// An outgoing message that arrives from outside the field (another
    /// device, a script): no morph, no field collapse.
    static var insert: SpringElement { element("transcript.insert") }
    static var bubbleRight: SpringElement { element("bubble.right") }
    static var bubbleWidth: SpringElement { element("bubble.width") }
    static var bubbleCenterY: SpringElement { element("bubble.centerY") }
    static var bubbleScale: SpringElement { element("bubble.scale") }
    static var bubbleOpacity: SpringElement { element("bubble.opacity") }
    static var fieldTop: SpringElement { element("field.top") }
    static var fieldOpacity: SpringElement { element("field.opacity") }

    /// A single-spring element for small effects that the recording does not
    /// constrain (fades, pops); same physics, one component.
    static func simple(_ name: String, delay: Double = 0, duration: Double, bounce: Double = 0) -> SpringElement {
        SpringElement(name: name, from: 0, to: 1, components: [.init(delay: delay, spring: Spring(duration: duration, bounce: bounce), delta: 1)])
    }
    /// Effects measured in earlier rounds (receipt pop, typing pop, reply fade),
    /// expressed as springs.
    static let typingPop = simple("typing.pop", delay: 0.05, duration: 0.209)
    static let typingFade = simple("typing.fade", delay: 0.05, duration: 0.12)
    static let typingOut = simple("typing.out", delay: 0.02, duration: 0.2)
    static let receivedFade = simple("received.fade", delay: 0.2, duration: 0.2)
    static let receiptIn = simple("receipt.in", delay: 0.085, duration: 0.15)
    static let receiptPop = simple("receipt.pop", delay: 0.085, duration: 0.251)
    static let receiptOldOut = simple("receipt.oldOut", delay: 0.042, duration: 0.163)   // fitted on luma, 6.55-7.25 s
    static let receiptNewIn = simple("receipt.newIn", delay: 0.262, duration: 0.243)    // fitted on luma, 6.55-7.25 s
    static let ghostOut = simple("row.out", delay: 0, duration: 0.2)
    static let connectorDraw = simple("connector.draw", delay: 0, duration: 0.25)
    static let textUnblur = simple("text.unblur", delay: 0.035, duration: 0.12)
    static let fieldGrow = simple("field.grow", delay: 0, duration: 0.1)
    static let scrollToBottom = simple("scroll.bottom", delay: 0, duration: 0.45, bounce: 0)
}

/// Adds additive spring animations. The model value is already the final
/// value; each component animates `-delta_i -> 0`, so the presented value is
/// `final + sum_i delta_i (p_i(t) - 1)`, which equals the fitted element.
/// Further animations on the same key path add up (no snap on interruption).
enum Animate {
    /// Animations added so far (also the key serial; the bench counts animations per commit).
    private(set) static var serial = 0

    /// Local time of `layer` now (virtual time when the root is paused).
    static func now(_ layer: CALayer) -> CFTimeInterval { layer.convertTime(CACurrentMediaTime(), from: nil) }

    /// Animate `keyPath` (a scalar sub key path such as "position.y",
    /// "bounds.size.width", "opacity", "transform.scale") from `from` to the
    /// model value `to` with `element`'s timing, starting at `begin`.
    @discardableResult
    static func scalar(_ layer: CALayer, _ keyPath: String, from: Double, to: Double, _ element: SpringElement,
                       begin: CFTimeInterval, delayShift: Double = 0) -> [String] {
        var keys: [String] = []
        for (i, c) in element.components.enumerated() {
            let d = element.isPulse ? c.delta : (to - from) * element.share(i)
            guard abs(d) > 1e-6 else { continue }
            if let curve = c.curve {
                keys.append(basic(layer, keyPath, delta: d, curve: curve, begin: begin + c.delay + delayShift, holdFrom: begin))
                continue
            }
            if c.delay + delayShift > 0 {
                // A component that starts later is committed as an additive
                // keyframe animation that starts now and samples the same
                // spring at 240 Hz (flat until its delay). The render server did
                // not hold `fillMode = .backwards` values for a spring whose
                // beginTime lay ahead in a paused (live-grab) tree.
                keys.append(sampled(layer, keyPath, delta: d, spring: c.spring, delay: c.delay + delayShift, begin: begin))
                continue
            }
            let a = CASpringAnimation(keyPath: keyPath)
            a.mass = 1
            a.stiffness = c.spring.stiffness
            a.damping = c.spring.damping
            a.initialVelocity = c.spring.initialVelocity
            a.fromValue = -d
            a.toValue = 0.0
            a.isAdditive = true
            a.beginTime = begin + c.delay + delayShift
            a.duration = c.spring.settlingTime()
            a.fillMode = .backwards
            a.isRemovedOnCompletion = true
            serial += 1
            let key = "spring.\(keyPath).\(serial)"
            layer.add(a, forKey: key)
            keys.append(key)
        }
        return keys
    }

    /// The render server clamps opacity while it sums additive animations, so
    /// an opacity pulse whose components leave [0, 1] is committed as one
    /// keyframe animation sampled from the same closed form (240 Hz). Core
    /// Animation still interpolates it on the render server.
    /// `depth` scales the pulse's excursion from `base` (1: the fitted pulse).
    static func sampledPulse(_ layer: CALayer, _ keyPath: String, _ element: SpringElement, base: Double, depth: Double = 1,
                             begin: CFTimeInterval) {
        let end = element.settleTime
        let n = max(2, Int(end * 240))
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = (0...n).map {
            NSNumber(value: min(1, max(0, base + depth * (element.value(Double($0) / 240, from: base, to: base) - base))))
        }
        a.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        a.duration = Double(n) / 240
        a.beginTime = begin
        a.calculationMode = .linear
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        serial += 1
        layer.add(a, forKey: "sampled.\(keyPath).\(serial)")
    }

    /// An absolute keyframe opacity that follows a pulse element down to its
    /// lowest value and then stays at 0 (a surface that leaves with the
    /// pulse's fade-out and does not come back). Sampled at 240 Hz.
    static func sampledUntilMinimum(_ layer: CALayer, _ keyPath: String, _ element: SpringElement, base: Double, begin: CFTimeInterval) {
        let n = max(2, Int(element.settleTime * 240))
        var values: [Double] = (0...n).map { min(1, max(0, element.value(Double($0) / 240, from: base, to: base))) }
        let low = values.indices.min { values[$0] < values[$1] } ?? n
        for i in low...n { values[i] = 0 }
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values.map { NSNumber(value: $0) }
        a.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        a.duration = Double(n) / 240
        a.beginTime = begin
        a.calculationMode = .linear
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        serial += 1
        layer.add(a, forKey: "sampled.\(keyPath).\(serial)")
    }

    /// `--x-two-animation-springs`: the hold-and-spring form in live trees too (the before arm of
    /// the A/B bench of the one-animation form; animations per send).
    static let twoAnimationForm = ProcessInfo.processInfo.arguments.contains("--x-two-animation-springs")

    /// Whether `layer` is in a paused tree (an ancestor with speed 0: captures, checks, live grabs),
    /// where the render server did not hold a backward fill for a start that lay ahead. A layer
    /// with no superlayer (a mask, a detached layer) counts as paused: the two-animation form is
    /// right in both trees.
    static func inPausedTree(_ layer: CALayer) -> Bool {
        if twoAnimationForm { return true }
        var l = layer
        while let up = l.superlayer {
            if l.speed == 0 { return true }
            l = up
        }
        return l === layer || l.speed == 0
    }

    /// Model opacity for "hidden" layers that still animate: the render
    /// server skips layers whose model opacity is exactly 0, animations or not.
    static let hiddenOpacity: Float = 0.01

    /// A delayed spring component without per-sample boxing: an additive hold
    /// at -delta from `begin` to `begin + delay` (two values), then a real
    /// CASpringAnimation from -delta to 0 that starts exactly when the hold
    /// ends. The spring has no backward fill (a paused tree did not honour it),
    /// so the sum is continuous at the hand-over in live and paused trees.
    /// (The earlier 240 Hz keyframe path boxed 150-300 NSNumbers per row per
    /// send: 485k main-thread allocations in 20 fast sends.)
    static func sampled(_ layer: CALayer, _ keyPath: String, delta d: Double, spring: Spring, delay: Double, begin: CFTimeInterval) -> String {
        if !inPausedTree(layer) {
            // A live tree holds a backward fill (only a paused tree did not): one animation, not
            // a hold and a spring. The same presented values (Presenter evaluates both alike).
            let a = CASpringAnimation(keyPath: keyPath)
            a.mass = 1
            a.stiffness = spring.stiffness
            a.damping = spring.damping
            a.initialVelocity = spring.initialVelocity
            a.fromValue = -d
            a.toValue = 0.0
            a.isAdditive = true
            a.beginTime = begin + delay
            a.duration = spring.settlingTime()
            a.fillMode = .backwards
            a.isRemovedOnCompletion = true
            serial += 1
            let key = "spring.\(keyPath).\(serial)"
            layer.add(a, forKey: key)
            return key
        }
        let hold = CAKeyframeAnimation(keyPath: keyPath)
        hold.values = [-d, -d]
        hold.beginTime = begin
        hold.duration = delay
        hold.isAdditive = true
        hold.fillMode = .backwards
        hold.isRemovedOnCompletion = true
        serial += 1
        layer.add(hold, forKey: "hold.\(serial)")
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = spring.stiffness
        a.damping = spring.damping
        a.initialVelocity = spring.initialVelocity
        a.fromValue = -d
        a.toValue = 0.0
        a.isAdditive = true
        a.beginTime = begin + delay
        a.duration = spring.settlingTime()
        a.isRemovedOnCompletion = true
        serial += 1
        let key = "spring.\(keyPath).\(serial)"
        layer.add(a, forKey: key)
        return key
    }

    /// A timing-curve component: an additive `CABasicAnimation` from -delta to
    /// 0. A start after `holdFrom` gets the same two-value hold as a delayed
    /// spring (no backward fill; a paused tree did not honour it).
    static func basic(_ layer: CALayer, _ keyPath: String, delta d: Double, curve: Curve, begin: CFTimeInterval,
                      holdFrom: CFTimeInterval) -> String {
        let live = begin > holdFrom && !inPausedTree(layer)
        if begin > holdFrom, !live {
            let hold = CAKeyframeAnimation(keyPath: keyPath)
            hold.values = [-d, -d]
            hold.beginTime = holdFrom
            hold.duration = begin - holdFrom
            hold.isAdditive = true
            hold.fillMode = .backwards
            hold.isRemovedOnCompletion = true
            serial += 1
            layer.add(hold, forKey: "hold.\(serial)")
        }
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = -d
        a.toValue = 0.0
        a.timingFunction = curve.timingFunction
        a.isAdditive = true
        a.beginTime = begin
        a.duration = curve.duration
        if begin <= holdFrom || live { a.fillMode = .backwards }
        a.isRemovedOnCompletion = true
        serial += 1
        let key = "curve.\(keyPath).\(serial)"
        layer.add(a, forKey: key)
        return key
    }

    /// A pulse element (from == to) on a layer whose model value is unchanged.
    @discardableResult
    static func pulse(_ layer: CALayer, _ keyPath: String, _ element: SpringElement, scale: Double = 1, begin: CFTimeInterval) -> [String] {
        var keys: [String] = []
        for c in element.components {
            if let curve = c.curve {
                keys.append(basic(layer, keyPath, delta: c.delta * scale, curve: curve, begin: begin + c.delay, holdFrom: begin))
                continue
            }
            if c.delay > 0 {
                keys.append(sampled(layer, keyPath, delta: c.delta * scale, spring: c.spring, delay: c.delay, begin: begin))
                continue
            }
            let a = CASpringAnimation(keyPath: keyPath)
            a.mass = 1
            a.stiffness = c.spring.stiffness
            a.damping = c.spring.damping
            a.initialVelocity = c.spring.initialVelocity
            a.fromValue = -c.delta * scale
            a.toValue = 0.0
            a.isAdditive = true
            a.beginTime = begin + c.delay
            a.duration = c.spring.settlingTime()
            a.fillMode = .backwards
            a.isRemovedOnCompletion = true
            // A pulse component is "delta * (p - 1)"; the components' deltas
            // sum to zero, so before the first start the sum is zero too.
            serial += 1
            let key = "pulse.\(keyPath).\(serial)"
            layer.add(a, forKey: key)
            keys.append(key)
        }
        return keys
    }
}

/// Closed-form evaluation of the animations in a layer tree at the layer's
/// local time. Capture uses it to render exact frames: it writes the presented
/// values into the model, renders, and restores the model.
enum Presenter {
    struct Saved { var layer: CALayer; var keyPath: String; var value: Any? }

    /// Presented minus model for one animation at local time `t` (nil: not active).
    static func contribution(_ anim: CAAnimation, at t: CFTimeInterval) -> (keyPath: String, delta: Double)? {
        if let s = anim as? CASpringAnimation, let kp = s.keyPath, s.isAdditive {
            let from = (s.fromValue as? NSNumber)?.doubleValue ?? 0, to = (s.toValue as? NSNumber)?.doubleValue ?? 0
            var tau = (t - s.beginTime) * Double(s.speed) + s.timeOffset
            if tau < 0 { if s.fillMode == .backwards || s.fillMode == .both { tau = 0 } else { return nil } }
            if tau > s.duration { return s.isRemovedOnCompletion ? nil : (kp, to) }
            let p = Spring.progress(tau, mass: s.mass, stiffness: s.stiffness, damping: s.damping, velocity: s.initialVelocity)
            return (kp, from + (to - from) * p)
        }
        if !(anim is CASpringAnimation), let b = anim as? CABasicAnimation, let kp = b.keyPath, b.isAdditive,
           let from = (b.fromValue as? NSNumber)?.doubleValue {
            let to = (b.toValue as? NSNumber)?.doubleValue ?? 0
            var tau = (t - b.beginTime) * Double(b.speed) + b.timeOffset
            if tau < 0 { if b.fillMode == .backwards || b.fillMode == .both { tau = 0 } else { return nil } }
            if tau > b.duration { return b.isRemovedOnCompletion ? nil : (kp, to) }
            var u = b.duration > 0 ? tau / b.duration : 1
            if let f = b.timingFunction {
                var p1: [Float] = [0, 0], p2: [Float] = [0, 0]
                f.getControlPoint(at: 1, values: &p1); f.getControlPoint(at: 2, values: &p2)
                u = Curve.solve(u, Double(p1[0]), Double(p1[1]), Double(p2[0]), Double(p2[1]))
            }
            return (kp, from + (to - from) * u)
        }
        if let k = anim as? CAKeyframeAnimation, let kp = k.keyPath, let values = k.values as? [NSNumber], values.count > 1 {
            var tau = (t - k.beginTime) * Double(k.speed) + k.timeOffset
            if tau < 0 {
                // Backward fill shows the first value before the start, as the
                // render server does (the hold of a delayed component).
                guard k.fillMode == .backwards || k.fillMode == .both else { return nil }
                tau = 0
            }
            let total = k.duration * Double(max(1, k.repeatCount))
            if k.repeatCount < .infinity, tau >= total { return k.isRemovedOnCompletion ? nil : (kp, values.last!.doubleValue) }
            // Wrap only repeating animations (a one-shot at exactly its end
            // must not wrap to its first value).
            if k.repeatCount > 1 { tau = tau.truncatingRemainder(dividingBy: k.duration) }
            let u = tau / k.duration
            let times = (k.keyTimes ?? []).map(\.doubleValue)
            let ts = times.count == values.count ? times : values.indices.map { Double($0) / Double(values.count - 1) }
            var i = 1
            while i < ts.count - 1, ts[i] < u { i += 1 }
            let f = max(0, min(1, (u - ts[i - 1]) / max(1e-9, ts[i] - ts[i - 1])))
            let v = values[i - 1].doubleValue + (values[i].doubleValue - values[i - 1].doubleValue) * f
            return (kp, v)
        }
        return nil
    }

    /// Apply presented values at the root's local time to the whole tree.
    /// Returns what to restore.
    static func apply(_ root: CALayer) -> [Saved] {
        var saved: [Saved] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        visit(root, &saved)
        CATransaction.commit()
        return saved
    }

    private static func visit(_ layer: CALayer, _ saved: inout [Saved]) {
        if let keys = layer.animationKeys(), !keys.isEmpty {
            let t = now(layer)
            var sums: [String: Double] = [:]
            var absolute: [String: Double] = [:]
            for k in keys {
                guard let a = layer.animation(forKey: k), let (kp, d) = contribution(a, at: t) else { continue }
                if (a as? CAPropertyAnimation)?.isAdditive == true { sums[kp, default: 0] += d } else { absolute[kp] = d }
            }
            for (kp, v) in absolute { saved.append(Saved(layer: layer, keyPath: kp, value: layer.value(forKeyPath: kp))); layer.setValue(v, forKeyPath: kp) }
            for (kp, d) in sums where abs(d) > 1e-9 {
                if kp == "transform.scale" {
                    // render(in:) draws only affine transforms; "transform.scale"
                    // also scales z, so write the 2-D equivalent.
                    let cur = Double(layer.transform.m11)
                    saved.append(Saved(layer: layer, keyPath: "transform", value: layer.value(forKey: "transform")))
                    layer.transform = CATransform3DMakeAffineTransform(CGAffineTransform(scaleX: CGFloat(cur + d), y: CGFloat(cur + d)))
                    continue
                }
                let cur = (layer.value(forKeyPath: kp) as? NSNumber)?.doubleValue ?? 0
                saved.append(Saved(layer: layer, keyPath: kp, value: layer.value(forKeyPath: kp)))
                layer.setValue(cur + d, forKeyPath: kp)
            }
        }
        layer.sublayers?.forEach { visit($0, &saved) }
    }

    static func restore(_ saved: [Saved]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in saved.reversed() { if s.keyPath == "transform" { s.layer.setValue(s.value, forKey: "transform") } else { s.layer.setValue(s.value, forKeyPath: s.keyPath) } }
        CATransaction.commit()
    }

    static func now(_ layer: CALayer) -> CFTimeInterval { layer.convertTime(CACurrentMediaTime(), from: nil) }
}
