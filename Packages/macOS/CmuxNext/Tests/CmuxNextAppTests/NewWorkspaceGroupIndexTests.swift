@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// A group formed for a new workspace (New Workspace in New Group) follows `workspaces.newPlacement`,
/// as the workspace itself does: first under `top` (the default), last otherwise. Before, the entry
/// always formed the group last, so the new group sat at the bottom of the sidebar under the default.
@MainActor
@Suite struct NewWorkspaceGroupIndexTests {
    @Test func topFormsTheGroupFirst() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: .top) == 0)
    }

    @Test func bottomAndAfterCurrentFormTheGroupLast() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: .bottom) == .max)
        #expect(NewWorkspacePlacements.newGroupIndex(for: .afterCurrent) == .max)
    }

    @Test func theDefaultPlacementFormsTheGroupFirst() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: CmuxConfigSnapshot.newWorkspacePlacementFallback) == 0)
    }
}
