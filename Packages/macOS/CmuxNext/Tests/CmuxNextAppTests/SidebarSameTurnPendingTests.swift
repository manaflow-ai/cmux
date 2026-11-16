import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// `SidebarSameTurn.runPending` runs, in the caller's turn, each pass that has a run to make: a pass that never
/// ran, and a pass whose value changed after its last run. A pass with nothing changed does not run, so the call
/// costs no second run. The window manager calls it before a window is ordered in.
///
/// No test here suspends, so no pass's task runs: each run that a test counts is a call's own.
@MainActor @Suite(.serialized) struct SidebarSameTurnPendingTests {
    /// The runs of one pass.
    @MainActor final class Runs {
        var computes = 0
        var applied: [Int] = []
    }

    /// One pass over `model` that reads the count of its spaces.
    private func make(_ model: SidebarModel, _ runs: Runs, listsRows: Bool = true) -> SidebarSameTurn {
        _ = NSApplication.shared
        let passes = SidebarSameTurn(view: SidebarView(model: model, design: DesignSettings()))
        passes.observe(listsRows: listsRows, {
            runs.computes += 1
            return model.profiles.count
        }) { runs.applied.append($0) }
        return passes
    }

    private func space(_ id: String) -> SidebarProfile { SidebarProfile(id: ProfileKey(id), name: id) }

    @Test func aPassThatNeverRanRunsInTheCallersTurn() {
        let model = SidebarModel(), runs = Runs()
        let passes = make(model, runs)
        defer { passes.cancel() }
        #expect(runs.computes == 0, "the pass ran in the turn that registered it")
        #expect(passes.runPending() == 1, "the call tells how many passes ran")
        #expect(runs.computes == 1)
        #expect(runs.applied == [0])
    }

    @Test func aPassWithNothingChangedDoesNotRunAgain() {
        let model = SidebarModel(), runs = Runs()
        let passes = make(model, runs)
        defer { passes.cancel() }
        passes.runPending()
        #expect(passes.runPending() == 0)
        #expect(runs.computes == 1, "the second call ran a pass that had nothing new to read")
    }

    @Test func aPassWhoseValueChangedRunsAgain() {
        let model = SidebarModel(), runs = Runs()
        let passes = make(model, runs)
        defer { passes.cancel() }
        passes.runPending()
        model.profiles = [space("a"), space("b")]
        passes.runPending()
        #expect(runs.applied == [0, 2])
    }

    /// A pass that `syncNow` ran in this turn has no run to make.
    @Test func aPassThatSyncNowRanDoesNotRunAgain() {
        let model = SidebarModel(), runs = Runs()
        let passes = make(model, runs)
        defer { passes.cancel() }
        passes.syncNow(rows: true)
        passes.runPending()
        #expect(runs.computes == 1)
    }

    /// The call runs each pass that waits, not only the rows pass.
    @Test func aPassThatDoesNotListRowsRunsToo() {
        let model = SidebarModel(), runs = Runs()
        let passes = make(model, runs, listsRows: false)
        defer { passes.cancel() }
        passes.runPending()
        #expect(runs.computes == 1)
    }

    /// The call in front of a window's order-in runs the passes that wait and keeps what it ran as the sample.
    @Test func theFirstFrameCallRunsThePassesAndKeepsItsSample() {
        let model = SidebarModel(), runs = Runs()
        let passes = make(model, runs)
        defer { passes.cancel() }
        #expect(passes.firstFrame == nil, "a sidebar that no window ordered in has a sample")
        passes.completeFirstFrame(sections: nil)
        #expect(runs.computes == 1)
        #expect(passes.firstFrame?.passes == 1)
        #expect(passes.firstFrame?.rows == 0, "the model of this test has no row")
    }
}
