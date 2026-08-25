import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SidebarDropPlannerPackageTests {
    @Test func pinnedGroupDropAfterItselfBeforeNextPinnedGroupIsNoOp() {
        let firstGroupId = UUID()
        let firstAnchorId = UUID()
        let firstChildId = UUID()
        let secondGroupId = UUID()
        let secondAnchorId = UUID()
        let secondChildId = UUID()

        let plan = SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 12, y: 31),
                draggedWorkspaceId: firstAnchorId,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: firstAnchorId,
                        isPinned: false,
                        groupId: firstGroupId
                    ),
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: firstChildId,
                        isPinned: false,
                        groupId: firstGroupId
                    ),
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: secondAnchorId,
                        isPinned: false,
                        groupId: secondGroupId
                    ),
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: secondChildId,
                        isPinned: false,
                        groupId: secondGroupId
                    ),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: firstGroupId,
                        anchorWorkspaceId: firstAnchorId,
                        isPinned: true
                    ),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: secondGroupId,
                        anchorWorkspaceId: secondAnchorId,
                        isPinned: true
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: firstAnchorId,
                        groupId: firstGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: secondAnchorId,
                        groupId: secondGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 40, width: 180, height: 32)
                    ),
                ]
            )
        )

        #expect(plan == nil)
    }

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

    @Test func ownGapIndicatorPaintsWhenNoOpSuppressionIsDisabled() {
        let ids = (0..<5).map { _ in UUID() }
        let planner = SidebarDropPlanner()

        // The gap directly below the dragged row is a no-op for the row
        // alone: suppressed by default, painted when the caller knows the
        // drag carries a noncontiguous block that coalesces there.
        let suppressed = planner.indicator(
            draggedTabId: ids[1],
            targetTabId: ids[1],
            tabIds: ids,
            pinnedTabIds: [],
            pointerY: 30,
            targetHeight: 32,
            suppressesNoOp: true
        )
        let painted = planner.indicator(
            draggedTabId: ids[1],
            targetTabId: ids[1],
            tabIds: ids,
            pinnedTabIds: [],
            pointerY: 30,
            targetHeight: 32,
            suppressesNoOp: false
        )

        #expect(suppressed == nil)
        #expect(painted != nil)
    }
}
