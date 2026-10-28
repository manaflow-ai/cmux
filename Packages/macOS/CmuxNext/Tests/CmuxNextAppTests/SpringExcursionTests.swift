import CmuxNextDesign
@testable import CmuxNextLayout
import CoreGraphics
import Testing

/// ``SpringParameters/excursion(displacement:velocity:)`` bounds the whole way of a spring, past its rest too (a
/// start with velocity, a bounce), and is no wider than that way: the visibility pass reads it for every pane a
/// motion carries. The way is sampled with the same closed form the frames step on
/// (`SpringValue.step`, cmux-motion), every 1/960 s for 4 s.
@MainActor @Suite struct SpringExcursionTests {
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        var response: Double
        var damping: Double
        var displacement: CGFloat
        var velocity: CGFloat

        var testDescription: String { "response \(response) damping \(damping) from \(displacement) at \(velocity)" }

        var parameters: SpringParameters { SpringParameters(response: response, dampingFraction: damping) }
    }

    nonisolated static let cases: [Case] = [
        // The scroll spring (0.9): a column's travel overshoots by under 2 pt; a throw from rest goes 30 pt.
        Case(response: 0.2, damping: 0.9, displacement: -1200, velocity: 0),
        Case(response: 0.2, damping: 0.9, displacement: 0, velocity: 2400),
        // Critically damped: no overshoot from rest; velocity away from the rest first goes further.
        Case(response: 0.3, damping: 1, displacement: -300, velocity: 0),
        Case(response: 0.3, damping: 1, displacement: 200, velocity: 1500),
        Case(response: 0.3, damping: 1, displacement: -60, velocity: 4000),
        // A bounce (`ui.animations.bounce` subtle) and a strong one.
        Case(response: 0.3, damping: 0.85, displacement: -300, velocity: 0),
        Case(response: 0.3, damping: 0.5, displacement: 100, velocity: -3000),
        // Over-damped.
        Case(response: 0.3, damping: 1.5, displacement: -100, velocity: 3000),
        Case(response: 0.25, damping: 1.2, displacement: -150, velocity: -900),
    ]

    /// The lowest and highest displacement the spring reaches, sampled.
    static func sampled(_ test: Case) -> (low: CGFloat, high: CGFloat) {
        var value = SpringValue(test.displacement)
        value.target = 0
        value.velocity = test.velocity
        var low = min(0, test.displacement), high = max(0, test.displacement)
        for _ in 0..<(4 * 960) {
            value.step(1.0 / 960, parameters: test.parameters)
            low = min(low, value.value)
            high = max(high, value.value)
        }
        return (low, high)
    }

    @Test(arguments: cases)
    func boundsTheWholeWayAndNoMore(_ test: Case) {
        let bound = test.parameters.excursion(displacement: test.displacement, velocity: test.velocity)
        let way = Self.sampled(test)
        #expect(way.low >= bound.low - 0.01 && way.high <= bound.high + 0.01, "the way \(way) leaves the bound \(bound)")
        #expect(abs(way.low - bound.low) < 0.05 && abs(way.high - bound.high) < 0.05, "the bound \(bound) is wider than the way \(way)")
    }

    @Test func aSpringAtRestGoesNowhere() {
        #expect(SpringParameters(response: 0.3, dampingFraction: 0.9).excursion(displacement: 0, velocity: 0) == .zero)
    }

    /// A frame whose four edges spring together (a split's pane moving and growing) stays inside its sweep on
    /// every step, and the sweep is the rest when nothing moves.
    @Test func aFramesSweepHoldsEveryRectOnItsWay() {
        let spring = SpringParameters(response: 0.3, dampingFraction: 0.85)
        var frame = AnimatedFrame(CGRect(x: 600, y: 0, width: 0, height: 800))
        frame.setTarget(CGRect(x: 300, y: 0, width: 300, height: 800))
        frame.x.velocity = -1500
        frame.width.velocity = 900
        let sweep = RectExcursion(frame, on: spring).sweep(around: frame.targetRect)
        for _ in 0..<(4 * 960) {
            _ = frame.advanceUnsettled(1.0 / 960, parameters: spring)
            #expect(sweep.insetBy(dx: -0.01, dy: -0.01).contains(frame.rect), "\(frame.rect) is outside the sweep \(sweep)")
        }
        let still = AnimatedFrame(CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(RectExcursion(still, on: spring).sweep(around: still.targetRect) == still.targetRect)
    }
}
