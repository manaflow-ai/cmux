import Foundation
import QuartzCore

/// Builds every Core Animation animation of the renderer (the only file that
/// constructs CAAnimation objects). Springs are additive: the model value is
/// already final and each component animates `-delta_i -> 0`, so the
/// presented value is `final + sum_i delta_i (p_i(t) - 1)`, the fitted
/// element. Further animations on the same key path add up, so an
/// interrupted change retargets from what is on screen (motion.md rule 6).
@MainActor
enum Animate {
    private static var serial = 0

    private static func nextKey(_ prefix: String) -> String {
        serial &+= 1
        return "\(prefix).\(serial)"
    }

    /// Local time of `layer` now.
    static func now(_ layer: CALayer) -> CFTimeInterval { layer.convertTime(CACurrentMediaTime(), from: nil) }

    /// Model opacity for hidden layers that still animate: the render server
    /// skips a layer whose model opacity is exactly 0, animations or not.
    static let hiddenOpacity: Float = 0.01

    private static func spring(_ keyPath: String, _ s: Spring, from: Double, begin: CFTimeInterval, duration: Double,
                               backwards: Bool) -> CASpringAnimation {
        // motion-allow: the render core's motion module (motion.md rule 1)
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = s.mass
        a.stiffness = s.stiffness
        a.damping = s.damping
        a.initialVelocity = s.initialVelocity
        a.fromValue = from
        a.toValue = 0.0
        a.isAdditive = true
        a.beginTime = begin
        a.duration = duration
        if backwards { a.fillMode = .backwards }
        a.isRemovedOnCompletion = true
        return a
    }

    /// Animates `keyPath` (a scalar key path such as "position.y",
    /// "bounds.size.width", "opacity", "transform.scale") from `from` to the
    /// model value `to` with `element`'s timing, starting at `begin`.
    static func scalar(_ layer: CALayer, _ keyPath: String, from: Double, to: Double, _ element: SpringElement,
                       begin: CFTimeInterval) {
        for (i, c) in element.components.enumerated() {
            let d = element.isPulse ? c.delta : (to - from) * element.share(i)
            guard abs(d) > 1e-6 else { continue }
            add(layer, keyPath, delta: d, c, begin: begin)
        }
    }

    /// A pulse element (`from == to`) on a layer whose model value does not change.
    static func pulse(_ layer: CALayer, _ keyPath: String, _ element: SpringElement, begin: CFTimeInterval) {
        for c in element.components { add(layer, keyPath, delta: c.delta, c, begin: begin) }
    }

    /// One component. A delayed one is an additive hold at -delta until its
    /// delay ends, then a spring that starts exactly there (no backward fill:
    /// a paused tree did not honour it), so the sum is continuous.
    private static func add(_ layer: CALayer, _ keyPath: String, delta d: Double, _ c: SpringElement.Component,
                            begin: CFTimeInterval) {
        guard c.delay > 0 else {
            layer.add(spring(keyPath, c.spring, from: -d, begin: begin + c.delay, duration: c.settle, backwards: true),
                      forKey: nextKey("spring.\(keyPath)"))
            return
        }
        // motion-allow: the render core's motion module (motion.md rule 1)
        let hold = CAKeyframeAnimation(keyPath: keyPath)
        hold.values = [-d, -d]
        hold.beginTime = begin
        hold.duration = c.delay
        hold.isAdditive = true
        hold.fillMode = .backwards
        hold.isRemovedOnCompletion = true
        layer.add(hold, forKey: nextKey("hold.\(keyPath)"))
        layer.add(spring(keyPath, c.spring, from: -d, begin: begin + c.delay, duration: c.settle, backwards: false),
                  forKey: nextKey("spring.\(keyPath)"))
    }

    /// The render server clamps opacity while it sums additive animations, so
    /// an opacity pulse whose components leave [0, 1] is committed as one
    /// keyframe animation sampled from the same closed form at 240 Hz.
    static func sampledPulse(_ layer: CALayer, _ keyPath: String, _ element: SpringElement, base: Double,
                             begin: CFTimeInterval) {
        let rate = 240.0
        let n = max(2, Int(element.settleTime * rate))
        // motion-allow: the render core's motion module (motion.md rule 1)
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = (0...n).map { NSNumber(value: min(1, max(0, element.value(Double($0) / rate, from: base, to: base)))) }
        a.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        a.duration = Double(n) / rate
        a.beginTime = begin
        a.calculationMode = .linear
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        layer.add(a, forKey: nextKey("sampled.\(keyPath)"))
    }

    /// Holds `keyPath` at `value` from `begin` until `end` (non-additive).
    static func hold(_ layer: CALayer, _ keyPath: String, value: Double, begin: CFTimeInterval, end: CFTimeInterval, key: String) {
        // motion-allow: the render core's motion module (motion.md rule 1)
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = [value, value]
        a.beginTime = begin
        a.duration = max(0, end - begin)
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        layer.add(a, forKey: key)
    }

    /// Fades `layer` from opaque to transparent over `duration` (Reduce Motion).
    static func fadeOut(_ layer: CALayer, begin: CFTimeInterval, duration: Double) {
        // motion-allow: the render core's motion module (motion.md rule 1)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.0
        a.duration = duration
        a.beginTime = begin
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        layer.add(a, forKey: "crossFade")
    }

    /// Typing dots: a Gaussian brightness pulse per dot, staggered, repeating
    /// on the render server (no main-thread work per frame).
    static func typingDot(_ layer: CALayer, index: Int, begin: CFTimeInterval) {
        let n = 60
        let width = HomeMotion.typingDotWidth
        var values: [NSNumber] = []
        values.reserveCapacity(n + 1)
        for k in 0...n {
            var x = Double(k) / Double(n) - 0.33 - Double(index) * HomeMotion.typingDotStagger
            x -= x.rounded()
            values.append(NSNumber(value: exp(-(x / width) * (x / width))))
        }
        // motion-allow: the render core's motion module (motion.md rule 1)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = values
        a.duration = HomeMotion.typingDotPeriod
        a.repeatCount = .infinity
        a.beginTime = begin
        a.isRemovedOnCompletion = false
        a.calculationMode = .linear
        layer.add(a, forKey: "dots")
    }

    /// Caret: solid after an edit, then a blink (render server); grey for a
    /// moment after a send.
    static func caret(_ layer: CALayer, begin: CFTimeInterval, sent: Bool, gray: CGColor) {
        layer.removeAnimation(forKey: "blink")
        // motion-allow: the render core's motion module (motion.md rule 1)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 1, 0, 0, 1].map { NSNumber(value: $0) }
        a.keyTimes = [0, 0.6, 0.65, 0.95, 1].map { NSNumber(value: $0) }
        a.duration = HomeMotion.caretPeriod
        a.repeatCount = .infinity
        a.beginTime = begin + HomeMotion.caretHold
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "blink")
        guard sent else { return }
        // motion-allow: the render core's motion module (motion.md rule 1)
        let g = CAKeyframeAnimation(keyPath: "backgroundColor")
        g.values = [gray, gray]
        g.beginTime = begin
        g.duration = HomeMotion.caretSendGray
        g.isRemovedOnCompletion = true
        layer.add(g, forKey: "sendGray")
    }
}
