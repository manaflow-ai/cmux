@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// A status indicator never says its state by color alone (audit 4, P4; WCAG 1.4.1 Use of Color). A
/// person who cannot tell orange from red saw the same dot for "needs you", "stopped" and "failed".
/// Every look keeps error and paused apart from waiting by shape; with the system's "Differentiate
/// without color" on, waiting draws its own figure too, so no two of these states share a glyph.
@MainActor struct StatusShapeNotColorTests {
    @Test func errorAndPausedNeverDrawWaitingsShape() {
        for set in StatusIconSet.allCases {
            for style in StatusIndicatorStyle.allCases {
                let waiting = StatusIndicatorPlan.make(.waiting, style: style, animates: true, set: set)
                for other in [StatusIndicatorState.error, .paused(progress: nil)] {
                    let plan = StatusIndicatorPlan.make(other, style: style, animates: true, set: set)
                    guard plan.glyph != .none else { continue }
                    #expect(plan.glyph != waiting.glyph, "\(other) draws waiting's \(waiting.glyph) in \(set), \(style)")
                }
            }
        }
    }

    @Test func errorAndPausedDrawDifferentShapes() {
        for set in StatusIconSet.allCases {
            for style in StatusIndicatorStyle.allCases {
                let error = StatusIndicatorPlan.make(.error, style: style, animates: true, set: set)
                let paused = StatusIndicatorPlan.make(.paused(progress: nil), style: style, animates: true, set: set)
                guard paused.glyph != .none else { continue }
                #expect(error.glyph != paused.glyph, "error and paused share \(error.glyph) in \(set), \(style)")
            }
        }
    }

    /// With "Differentiate without color" on, waiting, error, paused and success each draw a shape of
    /// their own in every set and style, and waiting is never a plain dot.
    @Test func withoutColorEveryStateHasItsOwnShape() {
        let states: [StatusIndicatorState] = [.waiting, .error, .paused(progress: nil), .success]
        for set in StatusIconSet.allCases {
            for style in StatusIndicatorStyle.allCases {
                for isStatic in [false, true] {
                    let glyphs = states.map {
                        StatusIndicatorPlan.make($0, style: style, animates: true, set: set, isStatic: isStatic, withoutColor: true).glyph
                    }.filter { $0 != .none }
                    #expect(Set(glyphs).count == glyphs.count, "two states share a shape in \(set), \(style), static \(isStatic): \(glyphs)")
                    #expect(glyphs.first != .dot, "waiting is a plain dot in \(set), \(style)")
                }
            }
        }
    }

    /// The default look keeps waiting's dot (WORKING-AND-LOADING-INDICATORS): only the system option changes it.
    @Test func waitingKeepsItsDotUnlessTheSystemAsks() {
        #expect(StatusIndicatorPlan.make(.waiting, style: .arc, animates: true).glyph == .dot)
        #expect(StatusIndicatorPlan.make(.waiting, style: .arc, animates: true, withoutColor: true).glyph == .mark(.glyph(.exclamation)))
        #expect(StatusIndicatorPlan.make(.waiting(kind: .permission), style: .arc, animates: true, withoutColor: true).glyph
            == .mark(.glyph(.hand)))
    }

    /// The config carries the system option, so every indicator host passes it to the plan.
    @Test func theConfigCarriesDifferentiateWithoutColor() {
        #expect(!StatusIndicatorConfig().differentiateWithoutColor)
        #expect(StatusIndicatorConfig(differentiateWithoutColor: true).differentiateWithoutColor)
    }
}
