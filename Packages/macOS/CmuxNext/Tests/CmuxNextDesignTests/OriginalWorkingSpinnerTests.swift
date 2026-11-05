import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The agent working spinner is the original 3/4 arc (as at e2e596e4b69a~1, before #29903), on
/// every surface that draws a `StatusIndicatorLayer`: sidebar rows, group headers, the tab bar,
/// hover cards and Home (Lawrence msg 19638: "we need it to be reverted back to original state").
/// The test reads the drawn layers, not the source: a bare arc of 0.72 of the circle at the
/// indicator's 1.5 pt stroke, with no track behind it, turning once per 0.9 s on the shared clock.
/// Changing it needs Lawrence's ask.
@MainActor @Suite(.serialized) struct OriginalWorkingSpinnerTests {
    private static func drawn(side: CGFloat, clock: SpinnerClock = SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000.45 })) -> StatusIndicatorLayer {
        let indicator = StatusIndicatorLayer(clock: clock)
        indicator.frame = CGRect(x: 0, y: 0, width: side, height: side)
        indicator.apply(StatusIndicatorPlan.working(tint: .spinner), config: StatusIndicatorConfig())
        return indicator
    }

    @Test func theWorkingPlanIsTheTurningArc() {
        #expect(StatusIndicatorPlan.working(tint: .spinner) == StatusIndicatorPlan(glyph: .arc, animation: .spin, tint: .spinner))
        for set in StatusIconSet.allCases {
            let plan = StatusIndicatorPlan.make(.working, style: .arc, animates: true, set: set)
            if plan.animation == .spin { #expect(plan.glyph == .arc, "\(set): \(plan)") }
        }
    }

    @Test(arguments: [12.0, 14.0, 16.0])
    func theArcIsThreeQuartersAtTheIndicatorStroke(side: Double) throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let indicator = Self.drawn(side: CGFloat(side))
        let arc = try #require(indicator.glyphLayer)
        #expect(arc.strokeStart == 0)
        #expect(abs(arc.strokeEnd - 0.72) < 1e-9, "arc share \(arc.strokeEnd)")
        #expect(arc.lineWidth == 1.5, "stroke \(arc.lineWidth)")
        #expect(arc.fillColor == nil)
        #expect(arc.frame.size == CGSize(width: side, height: side), "size \(arc.frame.size)")
        let box = try #require(arc.path?.boundingBoxOfPath)
        #expect(abs(box.width - (CGFloat(side) - 1.5)) < 1e-6, "ring diameter \(box.width)")
        // A bare arc: no faint track under it, no spokes.
        let shapes = indicator.layer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        #expect(shapes.filter { $0 !== arc && !$0.isHidden && $0.opacity > 0 }.isEmpty, "a track is drawn: \(shapes)")
        #expect(indicator.nativeLayer == nil)
    }

    @Test func itTurnsClockwiseOncePerPointNineSecondsOnTheSharedClock() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        #expect(MotionTunables.loopDefaults[.spinner]?.0 == 0.9)
        let indicator = Self.drawn(side: 14)
        let spin = try #require(indicator.glyphLayer?.animation(forKey: "spin") as? CABasicAnimation)
        #expect(spin.keyPath == "transform.rotation.z")
        #expect(spin.duration == 0.9, "period \(spin.duration)")
        #expect(spin.fromValue as? CGFloat == 0 && spin.toValue as? CGFloat == -2 * .pi)
        // Phase: Unix 1000.45 is 0.55 s into a 0.9 s turn, so the loop began 0.55 s before media 100.
        #expect(abs(spin.beginTime - 99.45) < 1e-6, "begin \(spin.beginTime)")
    }
}
