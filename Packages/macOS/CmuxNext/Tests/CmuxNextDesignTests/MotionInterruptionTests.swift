import AppKit
import QuartzCore
import Testing
@testable import CmuxNextDesign

/// A new change never waits for, restarts, or jumps over an animation in
/// flight: it starts from what is on screen and keeps the momentum.
@Suite struct MotionInterruptionTests {
    @Test func retargetingASpringMidwayContinuesFromItsPresentedValue() {
        let spring = MotionSpring.move.base
        var value = SpringValue(0)
        value.target = 200
        for _ in 0..<12 { value.step(1.0 / 120.0, parameters: spring) }
        let presented = value.value
        let velocity = value.velocity
        #expect(presented > 20 && presented < 180, "midway, not settled")

        // Interrupt: head back toward 0.
        value.target = 0
        #expect(value.value == presented)
        #expect(value.velocity == velocity)

        // The next frame moves by at most one frame of travel at the carried
        // velocity: no jump to either end.
        value.step(1.0 / 120.0, parameters: spring)
        #expect(abs(value.value - presented) <= abs(velocity) / 120.0 + 1)
        var frames = 0
        while value.advance(1.0 / 120.0, parameters: spring, epsilon: 0.25) {
            frames += 1
            #expect(frames < 120)
        }
        #expect(value.value == 0)
    }

    /// Core Animation computes presentation layers only for layers the
    /// window server renders, which a unit test cannot do without showing a
    /// window. This layer reports a fixed on-screen state instead, the way a
    /// layer does halfway through an animation.
    nonisolated final class MidAnimationLayer: CALayer, @unchecked Sendable {
        nonisolated(unsafe) var onScreen: MidAnimationLayer?
        override init() { super.init() }
        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { nil }
        override func presentation() -> Self? { onScreen as? Self }
    }

    @Test func layerSpringStartsFromThePresentationValue() throws {
        guard Motion.animatesMovement else { return }
        let layer = MidAnimationLayer()
        layer.position = CGPoint(x: 100, y: 0)
        let onScreen = MidAnimationLayer()
        onScreen.position = CGPoint(x: 50, y: 0)
        layer.onScreen = onScreen
        // The running animation that put it there.
        let running = CABasicAnimation(keyPath: "position.x")
        running.fromValue = 0
        running.toValue = 100
        running.duration = 1
        layer.add(running, forKey: "position.x")

        let next = try #require(Motion.set(layer, "position.x", to: CGFloat(300), spring: .move) as? CASpringAnimation)
        let from = try #require((next.fromValue as? NSNumber)?.doubleValue)
        #expect(from == 50, "starts from what is on screen, not the model value 100 or the old start 0")
        #expect((next.toValue as? NSNumber)?.doubleValue == 300)
        #expect(layer.position.x == 300)
        #expect(abs(next.stiffness - Motion.spring(.move).stiffness) < 1e-6)
        #expect(abs(next.damping - Motion.spring(.move).damping) < 1e-6)
        // The old animation was replaced, not queued behind.
        #expect(layer.animationKeys() == ["position.x"])
    }

    @Test func layerFadeStartsFromThePresentationValue() throws {
        guard Motion.animatesFades else { return }
        let layer = MidAnimationLayer()
        layer.opacity = 1
        let onScreen = MidAnimationLayer()
        onScreen.opacity = 0.4
        layer.onScreen = onScreen

        let next = try #require(Motion.set(layer, "opacity", to: Float(0), fade: .fadeOut) as? CABasicAnimation)
        #expect((next.fromValue as? NSNumber)?.floatValue == 0.4)
        #expect(next.duration == Motion.duration(.fadeOut))
        #expect(layer.opacity == 0)
    }

    @Test func withoutAPresentationTheModelValueIsTheStart() throws {
        guard Motion.animatesFades else { return }
        let layer = CALayer()
        layer.opacity = 0.7
        let next = try #require(Motion.set(layer, "opacity", to: Float(1), fade: .fadeIn) as? CABasicAnimation)
        #expect((next.fromValue as? NSNumber)?.floatValue == 0.7)
    }
}
