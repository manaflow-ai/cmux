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
}
