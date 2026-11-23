import AppKit
@testable import CmuxNextDesign
import Testing

/// A settle plays once on the success check a turn ends with (`playSettle`). When another still glyph
/// replaces the check before it ends (an error dot, a waiting dot), neither glyph loops, so the
/// layer used to keep the settle: the new glyph grew from 0.6 and eased in from the accent color.
@MainActor @Suite(.serialized) struct StatusIndicatorSettleTests {
    static let success = StatusIndicatorPlan(glyph: .check, animation: nil, tint: .success)

    static func indicator() -> StatusIndicatorLayer {
        let indicator = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000 }))
        indicator.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        let gray = CGColor(gray: 0.5, alpha: 1)
        indicator.colors = .init(loading: gray, attention: gray, danger: gray, success: gray, accent: gray, working: gray)
        return indicator
    }

    @Test(arguments: [StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .danger),
                      StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .attention)])
    func aStillGlyphReplacingTheSettlingCheckDoesNotSettle(_ next: StatusIndicatorPlan) throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let indicator = Self.indicator()
        indicator.apply(Self.success, config: StatusIndicatorConfig())
        indicator.playSettle()
        try #require(indicator.layer.animation(forKey: StatusIndicatorLayer.settleScaleKey) != nil,
                     "the check should settle")
        try #require(indicator.glyphLayer?.animation(forKey: StatusIndicatorLayer.settleTintKey) != nil,
                     "the check should ease in from the accent")
        indicator.apply(next, config: StatusIndicatorConfig())
        #expect(indicator.layer.animation(forKey: StatusIndicatorLayer.settleScaleKey) == nil,
                "the replacing glyph still grows in")
        #expect(indicator.glyphLayer?.animation(forKey: StatusIndicatorLayer.settleTintKey) == nil,
                "the replacing glyph still eases in from the accent")
    }

    @Test func aColorChangeOnTheSameCheckKeepsItsSettle() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let indicator = Self.indicator()
        indicator.apply(Self.success, config: StatusIndicatorConfig())
        indicator.playSettle()
        try #require(indicator.layer.animation(forKey: StatusIndicatorLayer.settleScaleKey) != nil)
        indicator.apply(StatusIndicatorPlan(glyph: .check, animation: nil, tint: .accent), config: StatusIndicatorConfig())
        #expect(indicator.layer.animation(forKey: StatusIndicatorLayer.settleScaleKey) != nil)
    }
}
