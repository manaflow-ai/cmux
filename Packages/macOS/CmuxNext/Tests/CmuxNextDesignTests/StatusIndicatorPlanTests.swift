import Testing
@testable import CmuxNextDesign

/// What each status draws in each style (plans/cmux-next/status-indicators.md).
struct StatusIndicatorPlanTests {
    @Test func idleDrawsNothingInEveryStyle() {
        for style in StatusIndicatorStyle.allCases {
            #expect(StatusIndicatorPlan.make(.idle, style: style, animates: true) == .hidden)
        }
    }

    @Test func indeterminateBusyFollowsTheStyle() {
        #expect(StatusIndicatorPlan.make(.busy, style: .arc, animates: true) == StatusIndicatorPlan(glyph: .arc, animation: .spin, tint: .loading))
        #expect(StatusIndicatorPlan.make(.busy, style: .native, animates: true) == StatusIndicatorPlan(glyph: .native, animation: .step, tint: .loading))
        #expect(StatusIndicatorPlan.make(.busy, style: .dot, animates: true) == StatusIndicatorPlan(glyph: .dot, animation: .pulse, tint: .loading))
        #expect(StatusIndicatorPlan.make(.busy, style: .none, animates: true) == .hidden)
    }

    @Test func knownProgressDrawsAStillRingExceptInNone() {
        for style in [StatusIndicatorStyle.arc, .native, .dot] {
            #expect(StatusIndicatorPlan.make(.busy(progress: 0.4), style: style, animates: true)
                == StatusIndicatorPlan(glyph: .ring(progress: 0.4), animation: nil, tint: .loading))
        }
        #expect(StatusIndicatorPlan.make(.busy(progress: 0.4), style: .none, animates: true) == .hidden)
    }

    @Test func progressIsClampedAndNonFiniteIsIndeterminate() {
        #expect(StatusIndicatorState.busy(progress: 1.7).progress == 1)
        #expect(StatusIndicatorState.busy(progress: -2).progress == 0)
        #expect(StatusIndicatorState.busy(progress: .nan).progress == nil)
        #expect(StatusIndicatorPlan.make(.busy(progress: .infinity), style: .arc, animates: true).glyph == .arc)
    }

    @Test func attentionStatesShowEvenWithStyleNone() {
        for style in StatusIndicatorStyle.allCases {
            #expect(StatusIndicatorPlan.make(.waiting, style: style, animates: true) == StatusIndicatorPlan(glyph: .dot, animation: .pulse, tint: .attention))
            #expect(StatusIndicatorPlan.make(.error, style: style, animates: true) == StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .danger))
            #expect(StatusIndicatorPlan.make(.success, style: style, animates: true) == StatusIndicatorPlan(glyph: .check, animation: nil, tint: .success))
        }
    }

    @Test func pausedUsesTheAttentionTintAndNeverAnimates() {
        #expect(StatusIndicatorPlan.make(.paused(progress: 0.5), style: .arc, animates: true)
            == StatusIndicatorPlan(glyph: .ring(progress: 0.5), animation: nil, tint: .attention))
        #expect(StatusIndicatorPlan.make(.paused(progress: nil), style: .native, animates: true)
            == StatusIndicatorPlan(glyph: .dot, animation: nil, tint: .attention))
        #expect(StatusIndicatorPlan.make(.paused(progress: 0.5), style: .none, animates: true) == .hidden)
    }

    @Test func nothingAnimatesWhenTheHostCannotBeSeen() {
        let states: [StatusIndicatorState] = [.busy, .busy(progress: 0.3), .paused(progress: nil), .waiting, .error, .success]
        for state in states {
            for style in StatusIndicatorStyle.allCases {
                let plan = StatusIndicatorPlan.make(state, style: style, animates: false)
                #expect(plan.animation == nil)
                #expect(plan.glyph == StatusIndicatorPlan.make(state, style: style, animates: true).glyph)
            }
        }
    }

    @Test func configStylePrecedenceIsOverrideThenHintThenSetting() {
        var config = StatusIndicatorConfig(settings: StatusIndicatorSettings(style: .dot))
        #expect(config.style(hint: nil) == .dot)
        #expect(config.style(hint: .native) == .native)
        config.styleOverride = .arc
        #expect(config.style(hint: .native) == .arc)
    }
}
