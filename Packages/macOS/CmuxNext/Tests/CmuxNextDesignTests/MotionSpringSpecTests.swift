import CmuxNextDesignTokens
import Foundation
import Testing

/// The spring tokens of this port and of the spec (design-tokens.json `motion`, the file
/// cmux-motion compiles its token table from) are one list with one set of values. No bounce in
/// any motion (Lawrence 2026-11-10): the spec holds no bounce setting and no damping under 1.
/// A change of screen has no animation (Lawrence 2026-11-10: "we should remove changing screen
/// animation"): no port holds a `screen` spring or its Motion Lab row.
@MainActor @Suite struct MotionSpringSpecTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The spec's `motion` object.
    static func motion() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("plans/cmux-next/spec-proposals/visuals/design-tokens.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["motion"] as? [String: Any], "design-tokens.json has no motion object")
    }

    @Test func theScreenSwitchSpringIsGoneFromThisPortAndTheSpec() throws {
        #expect(MotionSpring(rawValue: "screen") == nil, "MotionSpring still has the screen switch spring")
        #expect(!MotionTunables.all.contains { $0.key == "motion.spring.screen" }, "the Motion Lab still has a screen spring row")
        let springs = try #require(try Self.motion()["springs"] as? [String: Any])
        #expect(springs["screen"] == nil, "design-tokens.json motion.springs still has screen")
    }

    @Test func theSpecHoldsNoBounce() throws {
        let motion = try Self.motion()
        #expect(motion["bounce"] == nil, "design-tokens.json still has motion.bounce")
        #expect(motion["structural"] == nil, "design-tokens.json still has motion.structural (the set that followed the bounce)")
    }

    @Test func everySpringOfTheSpecIsThisPortsSpring() throws {
        let springs = try #require(try Self.motion()["springs"] as? [String: Any])
        try #require(springs.count >= 12, "SETUP: the spec lists \(springs.count) springs")
        for (name, entry) in springs.sorted(by: { $0.key < $1.key }) {
            let value = try #require((entry as? [String: Any])?["value"] as? [String: Any], "\(name) has no value")
            let response = try #require((value["response"] as? NSNumber)?.doubleValue, "\(name) has no response")
            let damping = try #require((value["dampingFraction"] as? NSNumber)?.doubleValue, "\(name) has no dampingFraction")
            #expect(damping >= 1, "the spec's \(name) spring has damping \(damping): it passes its target")
            let token = try #require(MotionSpring(rawValue: name), "the spec's \(name) spring is no MotionSpring of this port")
            let own = try #require(MotionTunables.springDefaults[token]?.0, "\(name) has no default")
            #expect(own.response == response, "\(name): response \(own.response) here, \(response) in the spec")
            #expect(own.dampingFraction == damping, "\(name): damping \(own.dampingFraction) here, \(damping) in the spec")
        }
    }
}
