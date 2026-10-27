import CmuxNextDesignTokens
import CmuxNextSettings
import Testing

/// `appearance.statusIndicator.animation` (cx-sya4n): `animated` by default, `static` stills
/// every status indicator. The Settings row (Appearance > Loading Indicator > Status Indicators)
/// offers both, defaults to the app's value and is agent-settable like its neighbours.
struct StatusIndicatorAnimationSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let indicator: JSONValue = value.map { .object(["animation": $0]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(["statusIndicator": indicator])]),
                                        validDensities: [], validMetrics: [])
    }

    @Test func animatedWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.statusIndicator.animation == .animated)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func staticAndAnimatedParse() {
        #expect(Self.parse(.string("static")).statusIndicator.animation == .static)
        #expect(Self.parse(.string("animated")).statusIndicator.animation == .animated)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("blinky"))
        #expect(snapshot.statusIndicator.animation == .animated)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.statusIndicator.animation" })
    }

    @Test func theSettingsRowOffersBothAndDefaultsToAnimated() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["appearance", "statusIndicator", "animation"]))
        #expect(row.defaultValue == .string("animated"))
        guard case .choice(let choices) = row.kind else {
            Issue.record("not a choice row: \(row.kind)")
            return
        }
        #expect(choices.map(\.value) == StatusIndicatorAnimation.allCases.map(\.rawValue))
        #expect(SettingsSchema.agentSettableKeys.contains("appearance.statusIndicator.animation"))
    }
}
