import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SidebarDropPlannerPackageTests {
    @Test func orderedWorkspaceDropTargetsMatchArrayWorkspaceAction() {
        let first = UUID()
        let second = UUID()
        let targets = [
            SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: second,
                isPinned: false,
                frame: CGRect(x: 0, y: 40, width: 180, height: 32)
            ),
            SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: first,
                isPinned: false,
                frame: CGRect(x: 0, y: 0, width: 180, height: 32)
            ),
        ]

        let planner = SidebarDropPlanner()
        let point = CGPoint(x: 12, y: 56)
        let orderedTargets = SidebarDropPlanner.OrderedWorkspaceDropTargets(targets)

        #expect(planner.workspaceAction(for: point, targets: orderedTargets) == .existingWorkspace(second))
        #expect(
            planner.workspaceAction(for: point, targets: orderedTargets) ==
                planner.workspaceAction(for: point, targets: targets)
        )
    }
}
