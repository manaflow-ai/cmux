@testable import CmuxNextApp
import CmuxNextSidebar
import CmuxNextWakeups
import Testing

/// p06-scheduler-302 (R-timer): the sidebar's selection hold ends at its limit through a `visible`
/// `MainDeadline` on the main thread's one wake-up queue, not a `DemandTimer`. A selected workspace
/// the rows never list (another space's) shows when the deadline fires; rows that list it first
/// show it at once and drop the deadline.
@MainActor
struct SidebarSelectionHoldDeadlineTests {
    private static let workspace = WorkspaceID("ws-unlisted")

    @Test func aSelectionTheRowsNeverListShowsWhenTheDeadlineFires() throws {
        let rig = MainDeadlineRig()
        let model = SidebarModel()
        let hold = SidebarSelectionHold(model: model, deadlines: rig.deadlines)
        hold.offer(.workspace(Self.workspace))
        #expect(model.selectedItem == nil, "a workspace with no row yet showed before its rows")
        let wake = try #require(rig.deadlines.nextFire, "the hold armed no deadline")
        #expect(wake >= SidebarSelectionHold.limit && wake <= SidebarSelectionHold.limit + WakeLeeway.defaultAlignment,
                "the hold wakes in WakeLeeway's window after its limit")
        rig.fireAndRun()
        #expect(model.selectedItem == .workspace(Self.workspace), "the deadline did not show the held selection")
        #expect(model.selection == [Self.workspace])
        #expect(rig.elapsed >= 0.25, "the held selection showed before its limit")
    }

    @Test func rowsThatShowTheSelectionDropTheDeadline() throws {
        let rig = MainDeadlineRig()
        let model = SidebarModel()
        let hold = SidebarSelectionHold(model: model, deadlines: rig.deadlines)
        hold.offer(.workspace(Self.workspace))
        #expect(rig.deadlines.nextFire != nil)
        hold.flush()
        #expect(model.selectedItem == .workspace(Self.workspace), "the rows' flush did not show the held selection")
        #expect(rig.deadlines.nextFire == nil, "the flushed hold left its deadline on the queue")
    }
}
