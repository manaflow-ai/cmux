@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// A group formed for a new workspace (New Workspace in New Group) follows
/// `workspaces.newPlacement`, as the workspace itself does: the explicit `top`
/// choice forms it first, while the next-to-current default and Bottom form it
/// last.
@MainActor
@Suite struct NewWorkspaceGroupIndexTests {
    @Test func topFormsTheGroupFirst() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: .top) == 0)
    }

    @Test func bottomAndAfterCurrentFormTheGroupLast() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: .bottom) == .max)
        #expect(NewWorkspacePlacements.newGroupIndex(for: .afterCurrent) == .max)
    }

    @Test func theDefaultPlacementFormsTheGroupLast() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: CmuxConfigSnapshot.newWorkspacePlacementFallback) == .max)
    }
}
