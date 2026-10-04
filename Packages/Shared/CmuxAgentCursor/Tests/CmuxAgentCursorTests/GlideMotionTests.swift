import Foundation
import Testing
@testable import CmuxAgentCursor

/// The same file the Rust cursor-overlay test replays against the real
/// macOS renderer (libs/cmux-cua/rust/crates/cursor-overlay/tests).
private func glideVectors() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CmuxAgentCursorTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // CmuxAgentCursor
        .deletingLastPathComponent() // swift
        .deletingLastPathComponent() // cmux-cua
        .appendingPathComponent("rust/crates/cursor-overlay/tests/glide_vectors.json")
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
}
