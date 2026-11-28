import Testing
@testable import CmuxNextDesign

/// A live resize step's start runs the one hook set for it (the CEF pump's due work), before the step lays out; a step
/// begun inside the hook's own work runs nothing more.
@MainActor
@Suite(.serialized) struct ResizeStepStartTests {
    @Test func aStepRunsTheHookOnce() {
        var runs = 0
        ResizeStepStart.willLayOut = { runs += 1 }
        defer { ResizeStepStart.willLayOut = nil }
        ResizeStepStart.begin()
        #expect(runs == 1)
        ResizeStepStart.begin()
        #expect(runs == 2)
    }

    @Test func aStepWhoseConditionFailsRunsNothing() {
        var runs = 0
        ResizeStepStart.willLayOut = { runs += 1 }
        defer { ResizeStepStart.willLayOut = nil }
        ResizeStepStart.begin(if: false)
        #expect(runs == 0)
    }

    @Test func theConditionIsReadOnlyWhileAHookIsSet() {
        var reads = 0
        ResizeStepStart.willLayOut = nil
        ResizeStepStart.begin(if: { reads += 1; return true }())
        #expect(reads == 0, "a divider's tick checks its drags only when something runs at the step")
    }

    @Test func aStepBegunInsideTheHookRunsNothingMore() {
        var runs = 0
        ResizeStepStart.willLayOut = {
            runs += 1
            ResizeStepStart.begin()  // a CEF callback inside the pass resized a view: its step starts here
        }
        defer { ResizeStepStart.willLayOut = nil }
        ResizeStepStart.begin()
        #expect(runs == 1)
    }
}
