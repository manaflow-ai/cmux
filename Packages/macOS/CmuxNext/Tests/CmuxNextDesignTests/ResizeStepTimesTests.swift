@testable import CmuxNextDesign
import Testing

/// `ResizeStepTimes` measures a phase inside another on one shared value: `ShellWindow.setFrame` measures the step,
/// and the layout root's `layout()`, which runs inside that `setFrame`, measures its screens' fit. As a `mutating`
/// method holding the shared value for the whole body, the inner measure was a second modification inside the first: a
/// Swift exclusivity trap ("Fatal access conflict detected") on the first live resize of a DEV build (other Mac,
/// 9f6ea72a, the first corner drag of resize_hitch).
@MainActor
@Suite(.serialized) struct ResizeStepTimesTests {
    static var shared = ResizeStepTimes()

    /// The fix: a phase takes its start with no access held, and records in one short write after its work, so the
    /// root's record inside `setFrame`'s never overlaps it. The red is this suite at the commit before (the nested
    /// closure-taking `measure`, which trapped).
    @Test func aMeasureInsideAnotherOnTheSameValueRecordsBoth() {
        Self.shared.reset()
        // The shape of setFrame (outer) and the root's layout inside it (inner), on one shared value.
        let outer = ResizeStepTimes.start()
        let inner = ResizeStepTimes.start()
        _ = (0..<100).reduce(0, +)
        Self.shared.record("inner", since: inner)
        Self.shared.record("outer", since: outer)
        let report = Self.shared.report()
        #expect(report["outer"]?["steps"] as? Int == 1)
        #expect(report["inner"]?["steps"] as? Int == 1)
        #expect((report["outer"]?["max_ms"] as? Double ?? 0) >= (report["inner"]?["max_ms"] as? Double ?? 0),
                "the outer step contains the inner one")
    }

    /// The parts of a step (each pane's layout, the sidebar, the overlay sync) are measured only in a live resize: out
    /// of one nothing is recorded and the phase's name is never built.
    @Test func aPartIsRecordedOnlyInALiveResize() {
        ResizeStepTimes.live.reset()
        var named = 0
        ResizeStepTimes.recordLive({ named += 1; return "pane_content.none" }(), since: ResizeStepTimes.startIfLive(false))
        ResizeStepTimes.recordLive({ named += 1; return "pane_content.none" }(), since: ResizeStepTimes.startIfLive(nil))
        #expect(named == 0)
        #expect(ResizeStepTimes.live.report().isEmpty)
        ResizeStepTimes.recordLive("pane_content.none", since: ResizeStepTimes.startIfLive(true))
        #expect(ResizeStepTimes.live.report()["pane_content.none"]?["steps"] as? Int == 1)
        ResizeStepTimes.live.reset()
    }
}
