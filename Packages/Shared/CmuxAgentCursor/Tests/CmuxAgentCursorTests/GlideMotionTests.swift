import Foundation
import Testing
@testable import CmuxAgentCursor

/// The same file the Rust cursor-overlay test replays against the real
/// macOS renderer (it includes this resource by path).
private func glideVectors() throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: "glide_vectors", withExtension: "json", subdirectory: "Resources"))
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

@Suite struct GlideMotionTests {
    @Test func matchesTheRustRendererSampleForSample() throws {
        let doc = try glideVectors()
        let tolerance = try #require(doc["tolerance"] as? Double)
        let cases = try #require(doc["cases"] as? [[String: Any]])
        #expect(cases.count >= 4)
        let motion = GlideMotion()
        #expect(motion.dt == (try #require(doc["dt"] as? Double)))
        for c in cases {
            let from = try #require(c["from"] as? [Double])
            let to = try #require(c["to"] as? [Double])
            let endHeading = try #require(c["end_heading"] as? Double)
            let positions = try #require(c["positions"] as? [[Double]])
            let headings = try #require(c["headings"] as? [Double])
            let plan = motion.plan(fromX: from[0], fromY: from[1], toX: to[0], toY: to[1], endHeading: endHeading)
            #expect(plan.samples.count == positions.count, "\(from) -> \(to)")
            #expect(plan.arrivedTick == (c["arrived_tick"] as? Int), "\(from) -> \(to)")
            for (i, sample) in plan.samples.enumerated() where i < positions.count {
                #expect(abs(sample.x - positions[i][0]) <= tolerance, "\(from) -> \(to) tick \(i + 1) x")
                #expect(abs(sample.y - positions[i][1]) <= tolerance, "\(from) -> \(to) tick \(i + 1) y")
                #expect(abs(sample.heading - headings[i]) <= tolerance, "\(from) -> \(to) tick \(i + 1) heading")
            }
        }
    }

    @Test func followIsAStraightConstantSpeedSegmentThatKeepsItsHeading() {
        let motion = GlideMotion()
        let plan = motion.follow(fromX: 10, fromY: 20, toX: 40, toY: 80, duration: 0.05, heading: 0.3)
        #expect(plan.samples.count == 6)
        #expect(plan.arrivedTick == 6)
        #expect(plan.origin == CGPoint(x: 10, y: 20))
        for (i, sample) in plan.samples.enumerated() {
            let u = Double(i + 1) / 6
            #expect(abs(sample.x - (10 + 30 * u)) < 1e-9)
            #expect(abs(sample.y - (20 + 60 * u)) < 1e-9)
            #expect(sample.heading == 0.3)
        }
        #expect(plan.samples.last == GlideSample(x: 40, y: 80, heading: 0.3))
    }

    @Test func followShorterThanOneTickStillLands() {
        let plan = GlideMotion().follow(fromX: 0, fromY: 0, toX: 5, toY: 5, duration: 0, heading: 0)
        #expect(plan.samples == [GlideSample(x: 5, y: 5, heading: 0)])
        #expect(plan.arrivedTick == 1)
    }
}
