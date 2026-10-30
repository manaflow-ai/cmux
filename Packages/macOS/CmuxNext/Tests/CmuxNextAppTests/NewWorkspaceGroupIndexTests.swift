@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// A group formed for a new workspace (New Workspace in New Group) follows
/// `workspaces.newPlacement`, preserving #24374's top-oriented section/new-group
/// behavior for the default and explicit `top`; explicit Bottom forms it last.
@MainActor
@Suite struct NewWorkspaceGroupIndexTests {
    @Test func topFormsTheGroupFirst() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: .top) == 0)
    }

    @Test func bottomFormsTheGroupLast() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: .bottom) == .max)
        #expect(NewWorkspacePlacements.newGroupIndex(for: .afterCurrent) == 0)
    }

    @Test func theDefaultPlacementFormsTheGroupFirst() {
        #expect(NewWorkspacePlacements.newGroupIndex(for: CmuxConfigSnapshot.newWorkspacePlacementFallback) == 0)
    }
}
