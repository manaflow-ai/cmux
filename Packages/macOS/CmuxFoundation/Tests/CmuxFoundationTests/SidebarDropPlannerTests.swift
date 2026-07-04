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

    @Test func rootScopedDropOverNestedGroupHeaderTargetsRootGroupAnchor() throws {
        let rootGroupId = UUID()
        let childGroupId = UUID()
        let rootAnchor = UUID()
        let childAnchor = UUID()
        let childMember = UUID()
        let dragged = UUID()
        let outside = UUID()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 12, y: 44),
                draggedWorkspaceId: dragged,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: rootAnchor, isPinned: false, groupId: rootGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childAnchor, isPinned: false, groupId: childGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childMember, isPinned: false, groupId: childGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: dragged, isPinned: false, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: outside, isPinned: false, groupId: nil),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(id: rootGroupId, anchorWorkspaceId: rootAnchor, isPinned: false),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: childGroupId,
                        anchorWorkspaceId: childAnchor,
                        isPinned: false,
                        parentGroupId: rootGroupId
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: rootAnchor,
                        groupId: rootGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: childAnchor,
                        groupId: childGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 12, y: 40, width: 168, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: childMember,
                        groupId: childGroupId,
                        isGroupHeader: false,
                        frame: CGRect(x: 24, y: 80, width: 156, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: dragged,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 120, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: outside,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 160, width: 180, height: 32)
                    ),
                ]
            )
        ))

        #expect(plan.indicator == SidebarDropIndicator(tabId: rootAnchor, edge: .top))
        #expect(plan.indicatorScope == .topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected top-level reorder plan")
            return
        }
        #expect(targetIndex == 0)
        #expect(usesTopLevelRows)
        #expect(explicitGroupId == nil)
    }
}
