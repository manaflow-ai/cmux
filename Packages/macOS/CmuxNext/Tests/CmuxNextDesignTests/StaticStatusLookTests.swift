import AppKit
@testable import CmuxNextDesign
import Testing

/// The static look (cx-sya4n: blinking and pulsing lights give a teammate headaches):
/// `appearance.statusIndicator.animation: "static"`, and always Reduce Motion, stills every
/// status indicator whatever the icon set. It draws the Static set's glyphs (#20410's
/// `StaticStatusGlyph`, Leo's call); the Debug toggle `status.static.shapes` draws one
/// `StatusMark` shape per state instead.
@MainActor @Suite(.serialized) struct StaticStatusLookTests {
    static let states: [StatusIndicatorState] = [
        .working(progress: nil), .busy(progress: nil), .paused(progress: nil), .waiting(kind: nil),
        .waiting(kind: .permission), .waiting(kind: .question), .waiting(kind: .auth), .error, .success,
    ]

    @Test func theStaticLookDrawsTheStaticSetStillWhateverTheIconSet() {
        for set in StatusIconSet.allCases {
            for state in Self.states {
                let plan = StatusIndicatorPlan.make(state, style: .arc, animates: true, set: set, isStatic: true)
                #expect(plan.animation == nil, "\(state) moves in the static look (\(set))")
                if let glyph = StaticStatusGlyph(state) {
                    #expect(plan == glyph.plan, "\(state) is not the Static set's glyph (\(set))")
                } else {
                    #expect(plan.glyph != .none, "\(state) draws nothing in the static look (\(set))")
                }
            }
            #expect(StatusIndicatorPlan.make(.idle, style: .arc, animates: true, set: set, isStatic: true) == .hidden)
        }
    }

    @Test func theShapesToggleGivesEveryStateItsOwnStillShape() {
        let plans = Self.states.map {
            StatusIndicatorPlan.make($0, style: .arc, animates: true, set: .codex, isStatic: true, staticShapes: true)
        }
        #expect(plans.allSatisfy { $0.animation == nil })
        #expect(Set(plans.map(\.glyph)).count == Self.states.count, "two states share a shape: \(plans.map(\.glyph))")
    }

    @Test func staticComesFromTheSettingOrReduceMotion() {
        var config = StatusIndicatorConfig()
        #expect(!config.isStatic)
        config.settings.animation = .static
        #expect(config.isStatic)
        config.settings.animation = .animated
        config.reduceMotion = true
        #expect(config.isStatic)

        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        #expect(StatusIndicatorConfig.current.reduceMotion)
        #expect(StatusIndicatorAppearance.shared.config.isStatic)
    }

    @Test func anIndicatorStandsStillOnTheStaticSetUnderReduceMotion() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.configure(.working(progress: nil))
        #expect(view.indicator.plan == StaticStatusGlyph.working.plan)
        #expect(view.indicator.runningAnimation == nil)
        view.configure(.waiting(kind: .permission))
        #expect(view.indicator.plan == StaticStatusGlyph.permission.plan)
    }
}
