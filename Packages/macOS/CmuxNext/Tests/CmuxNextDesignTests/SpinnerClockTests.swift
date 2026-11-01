import AppKit
@testable import CmuxNextDesign
import Testing

/// Spinners keep one phase: each loop's phase is Unix time mod its cycle (`SpinnerClock`), the
/// same clock the web pages' spinners read, so two spinners started at different moments, or in
/// different processes, sit at the same angle (Lawrence 2026-10-20).
@MainActor @Suite(.serialized) struct SpinnerClockTests {
    @Test func thePhaseIsUnixTimeModTheCycle() {
        let clock = SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000.25 })
        #expect(abs(clock.phase(cycle: 1) - 0.25) < 1e-9)
        #expect(abs(clock.beginTime(cycle: 1) - 99.75) < 1e-9)
        #expect(clock.beginTime(cycle: 0) == 100)
    }

    @Test func twoSpinnersStartedApartShareOnePhase() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let period = try #require(Motion.indicators.period(.spinner))
        // The media clock runs `offset` behind Unix time; the second spinner starts 0.37 s later.
        let offset = 1_760_000_000.123
        let early = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 500 }, unixTime: { 500 + offset }))
        let late = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 500.37 }, unixTime: { 500.37 + offset }))
        let plan = StatusIndicatorPlan(glyph: .arc, animation: .spin, tint: .loading)
        for indicator in [early, late] {
            indicator.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            indicator.apply(plan, config: StatusIndicatorConfig())
        }
        let first = try #require(early.glyphLayer?.animation(forKey: "spin"))
        let second = try #require(late.glyphLayer?.animation(forKey: "spin"))
        #expect(first.duration == period && second.duration == period)
        // Same phase at any shared moment: the begin times differ by whole turns only.
        let turns = (second.beginTime - first.beginTime) / period
        #expect(abs(turns - turns.rounded()) < 1e-6, "begin times \(first.beginTime) and \(second.beginTime) are out of step")
        // And the phase is the shared Unix-time phase, which the web pages read too.
        let phaseAt500 = ((500 - first.beginTime) / period).truncatingRemainder(dividingBy: 1)
        let unixPhase = (500 + offset).truncatingRemainder(dividingBy: period) / period
        #expect(abs(phaseAt500 - unixPhase) < 1e-6)
    }

    @Test func twoWorkingSpinnersStartedAcrossASleepShareOnePhase() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let period = try #require(Motion.indicators.period(.spinner))
        // The media clock stops while the Mac sleeps; Unix time does not. Read afresh per spinner
        // (the old default), Unix time put one started after a sleep out of step with one turning
        // since before it (Leo 2026-11-01: "why did you desync these"). The default clock now
        // counts from the media clock alone on one offset per process, so the two spinners below,
        // started 0.37 s apart on the media clock, share a phase whatever the wall clock did.
        let early = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 500 }))
        let late = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 500.37 }))
        let plan = StatusIndicatorPlan(glyph: .native, animation: .step, tint: .spinner)
        for indicator in [early, late] {
            indicator.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            indicator.apply(plan, config: StatusIndicatorConfig())
        }
        let first = try #require(early.nativeLayer?.animation(forKey: "step"))
        let second = try #require(late.nativeLayer?.animation(forKey: "step"))
        let turns = (second.beginTime - first.beginTime) / period
        #expect(abs(turns - turns.rounded()) < 1e-6, "begin times \(first.beginTime) and \(second.beginTime) are out of step")
        let clock = SpinnerClock(mediaTime: { 42 })
        #expect(abs(clock.unixTime() - 42 - SpinnerClock.processEpoch) < 1e-9)
    }

    @Test func spinnersTurnClockwise() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let spin = try #require(Motion.indicators.spinAnimation() as? CABasicAnimation)
        // Sublayers draw unflipped (`StatusIndicatorLayer.relayout`), where a negative angle is clockwise.
        let to = try #require(spin.toValue as? CGFloat)
        #expect(to < 0)
    }
}
