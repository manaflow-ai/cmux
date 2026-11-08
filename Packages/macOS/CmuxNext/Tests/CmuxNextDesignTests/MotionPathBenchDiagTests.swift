@testable import CmuxNextDesign
import QuartzCore
import Testing

/// DIAG ONLY (fix/pin-motionpath-bench-*-nomerge, never merges): the `// perf-hot: 0.01ms tab-switch` budget of
/// `MotionPath.value(at:)` (per cell, per sample), timed the same way at the base and at the pin-motion head. A cell's
/// position carries what a strip move puts on it: an additive spring, an additive eased basic move and a keyframe track;
/// its size an eased basic move. Each round samples 120 Hz over the move, 2000 times; the report gives ns per call.
@MainActor @Suite(.serialized) struct MotionPathBenchDiagTests {
    @Test func valueAtCost() {
        let now: CFTimeInterval = 1000
        let layer = CALayer()
        layer.position = CGPoint(x: 100, y: 10)
        layer.bounds = CGRect(x: 0, y: 0, width: 160, height: 28)
        let spring = CASpringAnimation(keyPath: "position")
        spring.fromValue = NSValue(point: CGPoint(x: -120, y: 0))
        spring.toValue = NSValue(point: .zero)
        spring.isAdditive = true
        spring.mass = 1; spring.stiffness = 300; spring.damping = 34.6
        spring.duration = spring.settlingDuration
        spring.beginTime = now + 0.004
        spring.fillMode = .backwards
        layer.add(spring, forKey: "a")
        let basic = CABasicAnimation(keyPath: "position.x")
        basic.fromValue = -40; basic.toValue = 0; basic.isAdditive = true; basic.duration = 0.3; basic.beginTime = now
        basic.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(basic, forKey: "b")
        let track = CAKeyframeAnimation(keyPath: "position")
        track.values = (0...40).map { NSValue(point: CGPoint(x: 100 + Double($0), y: 10)) }
        track.keyTimes = (0...40).map { NSNumber(value: Double($0) / 40) }
        track.duration = 0.35; track.beginTime = now
        layer.add(track, forKey: "c")
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = NSValue(size: CGSize(width: 32, height: 28)); size.toValue = NSValue(size: CGSize(width: 160, height: 28))
        size.duration = 0.3; size.beginTime = now
        layer.add(size, forKey: "d")
        let position = MotionPath(layer, "position", now: now), bounds = MotionPath(layer, "bounds.size", now: now)
        let times = MotionPath.times(from: now, to: now + 0.4, count: MotionPath.sampleCount(seconds: 0.4))
        var sink = 0.0
        var perCall: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<9 {
            let start = clock.now
            for _ in 0..<2000 {
                for time in times { sink += position.value(at: time).x + bounds.value(at: time).x }
            }
            let elapsed = clock.now - start
            let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            perCall.append(ns / Double(2000 * times.count * 2))
        }
        perCall.sort()
        print(String(format: "diag-mpbench value(at:) ns/call p50 %.1f min %.1f max %.1f (calls/round %d, sink %.0f)",
                     perCall[perCall.count / 2], perCall[0], perCall[perCall.count - 1], 2000 * times.count * 2, sink))
        #expect(sink.isFinite)
    }
}
