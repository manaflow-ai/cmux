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
