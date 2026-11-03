import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// WORKING-LOOK: agent work draws the spinner by default (Leo 2026-10-21: "WE SAID NO BLINKING. WE
/// SAID SPINNER."); the breathing and still accent dots stay as Debug choices, and loading (a page,
/// a command) keeps its spinner whatever the look.
@MainActor struct StatusWorkingLookTests {
    private static func plan(_ state: StatusIndicatorState, look: StatusWorkingLook, animates: Bool = true,
                             isStatic: Bool = false) -> StatusIndicatorPlan {
        StatusIndicatorPlan.make(state, style: .arc, animates: animates, set: .codex, isStatic: isStatic, working: look)
    }

    @Test func theSpinnerIsTheDefault() {
        #expect(StatusWorkingLook.tunable.defaultValue == .spinner)
    }

    @Test func workBreathesAsAnAccentDot() {
        #expect(Self.plan(.working, look: .breathe) == StatusIndicatorPlan(glyph: .dot, animation: .breathe, tint: .working))
        #expect(Self.plan(.working, look: .shimmer) == StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .working))
        #expect(Self.plan(.working, look: .spinner) == StatusIndicatorPlan(glyph: .sweep, animation: .spin, tint: .spinner))
    }

    /// The agent working-state mark is ChatGPT's ring with one gap, turning slowly (Leo 2026-11-02, on
    /// ChatGPT's beside ours: "THIS IS CHATGPT", "IT GOES SLOWER"): a bright arc of 0.72 of the ring
    /// over a faint track, a third heavier than the loading arc, one turn per 1.4 s. Not #31455's
    /// short 80° sweep, and never the macOS activity indicator's segmented spokes (#29903; Leo
    /// 2026-11-01: "why the f*** did you make the spinner into this????"). Pinned for every icon set.
    @Test func theWorkingSpinnerIsChatGPTsGapRingNeverTheSpokes() {
        #expect(StatusIndicatorPlan.workingGlyph == .sweep)
        #expect(StatusIndicatorPlan.workingArcLength == 0.72)
        #expect(StatusIndicatorPlan.workingStrokeScale == 4.0 / 3.0)
        #expect(MotionTunables.loopDefaults[.spinner]?.0 == 1.4)
        for set in StatusIconSet.allCases {
            let plan = StatusIndicatorPlan.make(.working, style: .arc, animates: true, set: set)
            #expect(plan.glyph != .native && plan.glyph != .arc && plan.animation != .step, "\(set): \(plan)")
            if plan.animation == .spin || plan.glyph == .sweep {
                #expect(plan.glyph == .sweep && plan.animation == .spin, "\(set): \(plan)")
            }
        }
    }

    /// The working ring draws as a faint full track plus the bright arc the spin turns, both at the
    /// working stroke.
    @Test func theWorkingRingDrawsATrackAndAHeavierTurningArc() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let indicator = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000 }))
        indicator.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        let config = StatusIndicatorConfig()
        indicator.apply(StatusIndicatorPlan.working(tint: .spinner), config: config)
        let arc = indicator.glyphLayer
        #expect(arc?.strokeEnd == CGFloat(StatusIndicatorPlan.workingArcLength))
        #expect(arc?.lineCap == .round)
        #expect(arc?.lineWidth == config.settings.thickness * 4 / 3)
        #expect(arc?.animation(forKey: "spin")?.duration == Motion.indicators.period(.spinner))
        let track = indicator.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0 !== arc }
        #expect(track != nil && track!.opacity > 0.1 && track!.opacity < 0.3)
        #expect(track?.lineWidth == arc?.lineWidth)
        #expect(indicator.nativeLayer == nil)
    }

    @Test func aHiddenOrStillRowHoldsTheDotStill() {
        // Occluded, off screen or loops off: the dot stays a dot, it does not turn into the work ring.
        #expect(Self.plan(.working, look: .breathe, animates: false) == StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .working))
        // The static look (Reduce Motion) keeps its own still glyphs.
        let still = Self.plan(.working, look: .breathe, isStatic: true)
        #expect(still.animation == nil && still.tint != .working)
    }

    @Test func loadingAndKnownProgressKeepTheirMarks() {
        for look in StatusWorkingLook.allCases {
            #expect(Self.plan(.busy, look: look).glyph == .arc, "\(look): loading keeps its spinner")
            #expect(Self.plan(.working(progress: 0.4), look: look).glyph == .ring(progress: 0.4), "\(look): known progress keeps its ring")
        }
    }

    @Test func theBreathIsCalmerThanTheWaitingPulse() {
        #expect(MotionLoop.breath.minimumPeriod >= 1)
        #expect((MotionTunables.loopDefaults[.breath]?.0 ?? 0) > (MotionTunables.loopDefaults[.pulse]?.0 ?? 0))
    }
}
