@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Testing

/// What each description and status action writes (`WorkspaceNotesUpdate`, the one value every
/// entrypoint sends as `workspace.update`), and which daemon capabilities it needs.
struct WorkspaceNotesUpdateTests {
    @Test func setWorkspaceStatusPinsALaneAndAutomaticClearsIt() {
        #expect(WorkspaceNotesUpdate(statusChoice: "auto") == WorkspaceNotesUpdate(taskStatus: .clear))
        #expect(WorkspaceNotesUpdate(statusChoice: "needs-attention") == WorkspaceNotesUpdate(taskStatus: .set(.needsAttention)))
        #expect(WorkspaceNotesUpdate(statusChoice: "inProgress") == nil, "the old placeholder lane is not a value")
        #expect(WorkspaceNotesUpdate.statusChoices == ["auto", "todo", "working", "needs-attention", "review", "done"])
    }

    /// Classic's cycle: todo, working, needs-attention, review, done, then todo again; a
    /// workspace on automatic starts at To Do.
    @Test func cycleWorkspaceStatusWalksTheClassicLanes() {
        #expect(WorkspaceNotesUpdate.cycled(nil) == .todo)
        var lane = WorkspaceTaskStatus.todo
        var walked: [WorkspaceTaskStatus] = []
        for _ in 0..<5 {
            lane = WorkspaceNotesUpdate.cycled(lane)
            walked.append(lane)
        }
        #expect(walked == [.working, .needsAttention, .review, .done, .todo])
    }

    @Test func eachFieldNeedsItsOwnCapability() {
        #expect(WorkspaceNotesUpdate(description: .set("notes")).capabilities == ["workspace-description-v1"])
        #expect(WorkspaceNotesUpdate(taskStatus: .set(.done)).capabilities == ["workspace-status-v1"])
        #expect(WorkspaceNotesUpdate().capabilities.isEmpty)
    }
}
