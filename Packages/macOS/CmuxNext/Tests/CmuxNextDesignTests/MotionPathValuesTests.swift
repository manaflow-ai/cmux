@testable import CmuxNextDesign
import QuartzCore
import Testing

/// `MotionPath` reads a layer's live animations into a path a tab strip samples per cell at 120 Hz on
/// every switch (`TabOcclusion.update`). It now decodes each animation once (QA spree 2026-10-23, P4:
/// the per-sample `objCType` strings, key path slices and timing-function arrays made a switch in a
/// 40-tab strip cost 9.3 ms against 1.8 ms at 4 tabs). These pin the values it reads from real Core
/// Animation animations on a layer: basic eased and linear, spring, keyframes linear and discrete,
/// additive moves on one component, a fill that holds, and an animation it cannot read.
@MainActor @Suite struct MotionPathValuesTests {
    static let now: CFTimeInterval = 1000

    static func layer(position: CGPoint = CGPoint(x: 100, y: 10), size: CGSize = CGSize(width: 50, height: 20)) -> CALayer {
        let layer = CALayer()
        layer.position = position
        layer.bounds = CGRect(origin: .zero, size: size)
        return layer
    }

    static func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    @Test func aLinearBasicMoveIsHalfwayAtHalfTime() {
        let layer = Self.layer()
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: CGPoint(x: 0, y: 0))
        move.toValue = NSValue(point: CGPoint(x: 200, y: 40))
        move.duration = 1
        layer.add(move, forKey: "move")
        let path = MotionPath(layer, "position", now: Self.now)
        #expect(path.isExact)
        #expect(path.end == Self.now + 1)
        #expect(Self.close(path.value(at: Self.now + 0.5), CGPoint(x: 100, y: 20)))
        // Before it starts and once it ended (no fill), the model shows.
        #expect(path.value(at: Self.now - 0.1) == layer.position)
        #expect(path.value(at: Self.now + 1.5) == layer.position)
    }

    @Test func anEasedMoveFollowsItsTimingFunction() {
        let layer = Self.layer()
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = 0
        move.toValue = 100
        move.duration = 1
        move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(move, forKey: "move")
        let value = MotionPath(layer, "position", now: Self.now).value(at: Self.now + 0.5)
        // Ease-in (0.42, 0, 1, 1) at half time is about 31.5% of the way; y stays the model's.
        #expect(value.x > 30 && value.x < 33, "eased x \(value.x)")
        #expect(value.y == layer.position.y)
    }

    @Test func aSpringStartsAtFromAndSettlesAtTo() {
        let layer = Self.layer(size: CGSize(width: 10, height: 20))
        let spring = CASpringAnimation(keyPath: "bounds.size.width")
        spring.fromValue = 10
        spring.toValue = 110
        spring.stiffness = 300
        spring.damping = 30
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "grow")
        let path = MotionPath(layer, "bounds.size", now: Self.now)
        #expect(Self.close(path.value(at: Self.now), CGPoint(x: 10, y: 20)))
        let late = path.value(at: Self.now + spring.settlingDuration - 0.0001)
        #expect(abs(late.x - 110) < 1, "settled width \(late.x)")
        #expect(late.y == 20)
        let mid = path.value(at: Self.now + 0.05).x
        #expect(mid > 10 && mid < 110, "mid width \(mid)")
    }

    @Test func keyframesInterpolateOrHoldEachValue() {
        let layer = Self.layer()
        let linear = CAKeyframeAnimation(keyPath: "position.x")
        linear.values = [0, 100, 0]
        linear.keyTimes = [0, 0.5, 1]
        linear.duration = 1
        layer.add(linear, forKey: "linear")
        #expect(abs(MotionPath(layer, "position", now: Self.now).value(at: Self.now + 0.25).x - 50) < 0.01)

        let held = Self.layer()
        let discrete = CAKeyframeAnimation(keyPath: "position.y")
        discrete.values = [5, 15, 25]
        discrete.calculationMode = .discrete
        discrete.duration = 0.9
        held.add(discrete, forKey: "steps")
        let path = MotionPath(held, "position", now: Self.now)
        #expect(path.value(at: Self.now + 0.1).y == 5)
        #expect(path.value(at: Self.now + 0.4).y == 15)
        #expect(path.value(at: Self.now + 0.8).y == 25)
    }

    @Test func additiveMovesSumOnTheirComponent() {
        let layer = Self.layer(position: CGPoint(x: 100, y: 10))
        for (key, offset) in [("a", -40.0), ("b", 10.0)] {
            let move = CABasicAnimation(keyPath: "position.x")
            move.isAdditive = true
            move.fromValue = offset
            move.toValue = 0
            move.duration = 1
            layer.add(move, forKey: key)
        }
        let path = MotionPath(layer, "position", now: Self.now)
        #expect(Self.close(path.value(at: Self.now), CGPoint(x: 70, y: 10)))
        #expect(Self.close(path.value(at: Self.now + 0.5), CGPoint(x: 85, y: 10)))
    }

    @Test func aFillThatHoldsKeepsTheLastValue() {
        let layer = Self.layer()
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: .zero)
        move.toValue = NSValue(point: CGPoint(x: 7, y: 9))
        move.duration = 0.2
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false
        layer.add(move, forKey: "hold")
        #expect(Self.close(MotionPath(layer, "position", now: Self.now).value(at: Self.now + 5), CGPoint(x: 7, y: 9)))
    }

    @Test func anAnimationItCannotReadAddsNothing() {
        let layer = Self.layer()
        let group = CAAnimationGroup()
        group.duration = 1
        let inner = CABasicAnimation(keyPath: "position")
        group.animations = [inner]
        layer.add(group, forKey: "group")
        let shake = CABasicAnimation(keyPath: "position")
        shake.fromValue = "not a point"
        shake.toValue = "nor this"
        shake.duration = 1
        layer.add(shake, forKey: "strings")
        let path = MotionPath(layer, "position", now: Self.now)
        #expect(path.value(at: Self.now + 0.5) == layer.position)
    }
}
