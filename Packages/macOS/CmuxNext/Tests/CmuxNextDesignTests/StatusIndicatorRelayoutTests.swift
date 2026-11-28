import AppKit
@testable import CmuxNextDesign
import Testing

/// An agent's working/idle flip applied the row's status plan, which built the spinner, and then the
/// host view's layout pass asked the layer to lay out again at the same frame, which built it a
/// second time: a new path on the same shape layer, drawn again at the next commit, on every flip of
/// every ticking sidebar row (`sidebar.400.ticking.main_ms_per_s`, stable gate item 3). A layout with
/// nothing changed now builds nothing; a new frame, scale or flip still builds.
@MainActor @Suite(.serialized) struct StatusIndicatorRelayoutTests {
    static let spin = StatusIndicatorPlan(glyph: .arc, animation: .spin, tint: .loading)

    static func indicator() -> StatusIndicatorLayer {
        let indicator = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000 }))
        indicator.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        return indicator
    }

    @Test func aLayoutAfterAnApplyBuildsNothing() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let indicator = Self.indicator()
        indicator.apply(Self.spin, config: StatusIndicatorConfig())
        let builds = indicator.glyphBuilds
        let shape = indicator.glyphLayer
        let path = shape?.path
        for _ in 0..<3 { indicator.relayout() }
        #expect(indicator.glyphBuilds == builds, "a layout at the same frame built the spinner again")
        #expect(indicator.glyphLayer === shape)
        #expect(indicator.glyphLayer?.path === path, "the spinner's shape got a new path")
        #expect(indicator.runningAnimation == .spin, "the spin keeps running through the layout")
    }

    @Test func aNewFrameScaleOrFlipBuildsAgain() {
        let indicator = Self.indicator()
        indicator.apply(Self.spin, config: StatusIndicatorConfig())
        var builds = indicator.glyphBuilds
        indicator.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        #expect(indicator.glyphBuilds == builds + 1)
        #expect(indicator.glyphLayer?.frame.width == 20)
        builds = indicator.glyphBuilds
        indicator.contentsScale = 1
        #expect(indicator.glyphBuilds == builds + 1)
        builds = indicator.glyphBuilds
        indicator.hostIsFlipped = !(indicator.hostIsFlipped ?? false)
        #expect(indicator.glyphBuilds == builds + 1)
    }

    /// A row that goes idle and works again shows its spinner at once, built for its frame.
    @Test func anIdleFlipThenWorkingAgainShowsTheSpinner() {
        let indicator = Self.indicator()
        indicator.apply(Self.spin, config: StatusIndicatorConfig())
        indicator.apply(.hidden, config: StatusIndicatorConfig())
        indicator.relayout()
        #expect(indicator.glyphLayer == nil)
        indicator.apply(Self.spin, config: StatusIndicatorConfig())
        indicator.relayout()
        #expect(indicator.glyphLayer?.path != nil)
        #expect(indicator.glyphLayer?.frame == indicator.glyphRect)
    }
}
