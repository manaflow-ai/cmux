#if canImport(QuartzCore)
import QuartzCore
import Testing
@testable import CmuxAgentCursor

@Suite struct GlidePlanAnimationTests {
    @Test func positionKeyframesFollowEverySampleAndEndOnTheTarget() throws {
        let plan = GlideMotion().plan(fromX: 0, fromY: 0, toX: 400, toY: 0, endHeading: .pi / 4)
        let animation = plan.positionAnimation()
        let values = try #require(animation.values as? [NSValue])
        #expect(values.count == plan.samples.count + 1, "start point plus one keyframe per sample")
        #expect(values.first?.pointValue == CGPoint(x: 0, y: 0))
        #expect(values.last?.pointValue == CGPoint(x: 400, y: 0))
        let times = try #require(animation.keyTimes?.map(\.doubleValue))
        #expect(times.count == values.count)
        #expect(times.first == 0)
        #expect(times.last == 1)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
        #expect(abs(animation.duration - plan.duration) < 1e-9)
        #expect(animation.calculationMode == .linear)
    }

    @Test func rotationEndsAtTheRestingHeading() throws {
        let plan = GlideMotion().plan(fromX: 0, fromY: 0, toX: 0, toY: 300, endHeading: 2.0)
        let animation = plan.rotationAnimation()
        let values = try #require(animation.values as? [Double])
        #expect(values.count == plan.samples.count + 1)
        #expect(values.last == 2.0)
        #expect(abs(animation.duration - plan.duration) < 1e-9)
    }
}
#endif

@Suite struct CodexGlideTests {
    @Test func straightNoOvershootAndSettlesFast() {
        let plan = GlideMotion().codexPlan(fromX: 0, fromY: 0, toX: 300, toY: 0, endHeading: 0)
        #expect(plan.samples.allSatisfy { $0.y == 0 && $0.x <= 300 }, "straight, never past the target")
        #expect(zip(plan.samples, plan.samples.dropFirst()).allSatisfy { $0.x <= $1.x })
        #expect(plan.samples.last?.x == 300)
        #expect(plan.duration < 0.6)
        let half = plan.samples[plan.samples.count / 4]
        #expect(half.x > 150, "most of the way early, then a soft settle")
    }
}
