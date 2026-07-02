import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SidebarWorkspaceCloseOtherPlannerTests {
    @Test func closesEveryOtherWorkspaceWhenNoTagFilterIsActive() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let toClose = SidebarWorkspaceCloseOtherPlanner().workspaceIdsToClose(
            fullOrderWorkspaceIds: [a, b, c, d],
            keptWorkspaceIds: [b],
            activeWorkspaceTagFilter: nil
        )
        #expect(toClose == [a, c, d])
    }

    @Test func excludesFilterHiddenWorkspacesWhileTagFilterIsActive() {
        // With a tag filter active, only matching rows are visible and the kept set is
        // a visible row. Resolving "the rest" against the full order would close the
        // hidden, non-matching workspaces the user cannot see — silent data loss. The
        // planner must refuse while filtered (matching the disabled Close Above/Below
        // items), yielding no ids so no hidden workspace is closed.
        let visibleKept = UUID()
        let hiddenA = UUID()
        let hiddenB = UUID()
        let toClose = SidebarWorkspaceCloseOtherPlanner().workspaceIdsToClose(
            fullOrderWorkspaceIds: [hiddenA, visibleKept, hiddenB],
            keptWorkspaceIds: [visibleKept],
            activeWorkspaceTagFilter: "backend"
        )
        #expect(toClose == [])
    }
}
