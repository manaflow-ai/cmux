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

    /// The agent working-state mark is a faint full ring with a short bright sweep turning smoothly,
    /// as in Claude and ChatGPT: never the 3/4 arc alone (Leo 2026-10-31: "who even decided to put that
    /// 3/4 circle") and never the macOS activity indicator's segmented spokes (#29903; Leo 2026-11-01:
    /// "why the f*** did you make the spinner into this????"). Pinned for every icon set.
    @Test func theWorkingSpinnerIsARingWithASweepNeverTheArcOrSpokes() {
        #expect(StatusIndicatorPlan.workingGlyph == .sweep)
        #expect(StatusIndicatorPlan.sweepLength > 0.15 && StatusIndicatorPlan.sweepLength < 0.26)
        for set in StatusIconSet.allCases {
            let plan = StatusIndicatorPlan.make(.working, style: .arc, animates: true, set: set)
            #expect(plan.glyph != .native && plan.glyph != .arc && plan.animation != .step, "\(set): \(plan)")
            if plan.animation == .spin || plan.glyph == .sweep {
                #expect(plan.glyph == .sweep && plan.animation == .spin, "\(set): \(plan)")
            }
        }
    }

    /// The sweep draws as a faint full track plus a short bright arc that the spin turns.
    @Test func theWorkingSweepDrawsATrackAndAShortTurningArc() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let indicator = StatusIndicatorLayer(clock: SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000 }))
        indicator.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        indicator.apply(StatusIndicatorPlan.working(tint: .spinner), config: StatusIndicatorConfig())
        let sweep = indicator.glyphLayer
        #expect(sweep?.strokeEnd == CGFloat(StatusIndicatorPlan.sweepLength))
        #expect(sweep?.lineCap == .round)
        #expect(sweep?.animation(forKey: "spin") != nil)
        let track = indicator.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0 !== sweep }
        #expect(track != nil && track!.opacity > 0.1 && track!.opacity < 0.3)
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
