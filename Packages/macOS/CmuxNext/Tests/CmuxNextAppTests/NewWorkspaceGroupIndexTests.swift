@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// A group formed for a new workspace (New Workspace in New Group) follows `workspaces.newPlacement`,
/// as the workspace itself does: last only under `bottom`, else first. Before, the entry always formed
/// the group last, so the new group sat at the bottom of the sidebar; `afterCurrent` (the default since
/// 2026-11-06) never sends a new workspace there.
@MainActor
@Suite struct NewWorkspaceGroupIndexTests {
    @Test func topFormsTheGroupFirst() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: .top) == 0)
    }

    @Test func onlyBottomFormsTheGroupLast() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: .bottom) == .max)
        #expect(NewWorkspacePlacements.newGroupIndex(for: .afterCurrent) == 0)
    }

    @Test func theDefaultPlacementFormsTheGroupFirst() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: CmuxConfigSnapshot.newWorkspacePlacementDefault) == 0)
    }
}
