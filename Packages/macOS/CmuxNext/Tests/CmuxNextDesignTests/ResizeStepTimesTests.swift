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

    /// Lever 4e: the CEF host runs the message pump work CEF asked for at the start of each resize step, before its
    /// layout (`CEFMessagePump.runIfDueAtStep`). The hook runs at every step, timed or not, once the step is open (its
    /// time is the step's); not for a call that is no step. A step begun and a pane laid out inside the pass (a CEF
    /// callback that reached cmux's views mid-step) are counted on the pass's line (`nested=`), never hooked again.
    @Test func aStepHookRunsAtEveryStepAndCountsWhatRunsInsideAPass() {
        ResizeStepTimes.live.reset()
        ResizeStepLog.reset()
        defer {
            ResizeStepTimes.live.stepWillLayOut = nil
            ResizeStepTimes.recordingOverride = nil
            ResizeStepLog.reset()
            ResizeStepTimes.live.reset()
        }
        var hooked: [ResizeStepTimes.StepKind] = []
        var openAtHook: [Bool] = []
        ResizeStepTimes.live.stepWillLayOut = { kind in
            hooked.append(kind)
            openAtHook.append(ResizeStepLog.step != nil)
        }
        ResizeStepTimes.recordingOverride = false
        #expect(ResizeStepTimes.beginStep(.window) == nil, "untimed: no start")
        #expect(hooked == [.window], "an untimed step is hooked too (a Release build nobody streams)")
        ResizeStepTimes.recordingOverride = true
        #expect(ResizeStepTimes.beginStep(.divider) != nil)
        #expect(hooked == [.window, .divider])
        #expect(openAtHook == [false, true], "a timed step is open when its hook runs")
        _ = ResizeStepTimes.beginStep(.divider, if: false)
        #expect(hooked.count == 2, "no step, no hook")

        let before = ResizeStepTimes.live.nestedInPass
        ResizeStepTimes.pass("cef_pump") {
            _ = ResizeStepTimes.beginStep(.window)
            ResizeStepTimes.recordLive("pane_layout", since: ResizeStepTimes.start())
            return " ran=1"
        }
        #expect(hooked.count == 2, "a step inside a pass is not hooked")
        #expect(ResizeStepTimes.live.nestedInPass - before == 2, "the step and the pane's layout inside the pass")
        #expect(ResizeStepTimes.live.report()["cef_pump"]?["steps"] as? Int == 1, "the pass is a phase of the step")
        ResizeStepTimes.pass("cef_pump") { nil }
        #expect(ResizeStepTimes.live.report()["cef_pump"]?["steps"] as? Int == 1,
                "a pass with nothing to do writes no line")
    }

    /// A divider drag's step is its frame tick and what its turn lays out until the commit: a pane laid out in it is
    /// timed with no live resize, under `divider.`, and the step ends after the commit. With steps not timed (a Release
    /// build nobody streams) no step begins and its condition is never read.
    @Test func aDividerStepTimesItsPartsUntilItsCommit() {
        ResizeStepTimes.live.reset()
        ResizeStepLog.reset()
        defer { ResizeStepTimes.recordingOverride = nil; ResizeStepLog.reset(); ResizeStepTimes.live.reset() }
        ResizeStepTimes.recordingOverride = false
        var read = 0
        #expect(ResizeStepTimes.beginStep(.divider, if: { read += 1; return true }()) == nil)
        #expect(read == 0)
        #expect(ResizeStepTimes.startIfLive(false) == nil)

        ResizeStepTimes.recordingOverride = true
        let tick = ResizeStepTimes.beginStep(.divider)
        #expect(tick != nil)
        // A pane's layout inside the tick, the tick, then the commit observer's two marks.
        ResizeStepTimes.recordLive("pane_layout", since: ResizeStepTimes.startIfLive(false))
        ResizeStepTimes.recordLive("tick", since: tick)
        ResizeStepLog.precommit()
        ResizeStepLog.committed(.beforeWaiting)
        #expect(ResizeStepLog.step == nil)
        #expect(ResizeStepTimes.startIfLive(false) == nil, "after its commit nothing more is part of the step")
        let report = ResizeStepTimes.live.report()
        for phase in ["divider.pane_layout", "divider.tick", "divider.step_precommit", "divider.step_commit"] {
            #expect(report[phase]?["steps"] as? Int == 1, "\(phase)")
        }
        #expect(report["pane_layout"] == nil, "a divider step's parts are not the window's")
    }

    /// The bench's lean log (`CMUX_NEXT_STEP_LOG=lean`): a step writes the lines of a lean phase (its set_frame, its
    /// commit) and none of a pane's part, whose detail is never built; the full log writes both. Counted on the step's
    /// own line count (`lines=` on its `step_commit`).
    @Test func aLeanLogWritesOnlyTheStepsOwnLines() {
        ResizeStepTimes.live.reset()
        ResizeStepLog.reset()
        defer { ResizeStepTimes.recordingOverride = nil; ResizeStepLog.reset(); ResizeStepTimes.live.reset() }
        ResizeStepTimes.recordingOverride = true
        ResizeStepLog.streamingOverride = true
        func linesOfAStep(lean: Bool) -> (lines: Int, detailsBuilt: Int) {
            ResizeStepLog.leanOverride = lean
            var built = 0
            let start = ResizeStepTimes.beginStep(.window)
            let before = ResizeStepLog.step?.lines ?? 0
            ResizeStepTimes.recordLive("pane_layout", since: ResizeStepTimes.start(), detail: { built += 1; return "" }())
            ResizeStepTimes.note("page_window_geometry", ms: 0, detail: { built += 1; return " what=resize" }())
            ResizeStepTimes.recordLive("set_frame", since: start, detail: { built += 1; return " w=800" }())
            let lines = (ResizeStepLog.step?.lines ?? 0) - before
            ResizeStepLog.precommit()
            ResizeStepLog.committed(.beforeWaiting)
            return (lines, built)
        }
        let full = linesOfAStep(lean: false)
        #expect(full.lines == 3, "the full log writes the pane's part, the page window's note and the set_frame")
        #expect(full.detailsBuilt == 3)
        let lean = linesOfAStep(lean: true)
        #expect(lean.lines == 1, "a lean log writes only the step's set_frame, not \(lean.lines) lines")
        #expect(lean.detailsBuilt == 1, "a lean log built the detail of a line it does not write")
    }
}
