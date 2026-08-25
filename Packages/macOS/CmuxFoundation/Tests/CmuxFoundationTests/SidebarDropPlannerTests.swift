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

    @Test func droppingWorkspaceOnEmptyGroupHeaderProducesExplicitGroupPlan() throws {
        let groupId = UUID()
        let headerId = UUID()
        let draggedId = UUID()
        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 12, y: 24),
                draggedWorkspaceId: draggedId,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: draggedId,
                        isPinned: false,
                        groupId: nil
                    ),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: groupId,
                        anchorWorkspaceId: headerId,
                        isPinned: true,
                        isEmpty: true
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: headerId,
                        groupId: groupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                ]
            )
        ))

        guard case .reorder(_, _, let explicitGroupId) = plan.action else {
            Issue.record("expected an explicit group reorder")
            return
        }
        #expect(explicitGroupId == groupId)
        #expect(plan.indicator?.tabId == headerId)
    }

    @Test func draggingEmptyGroupHeaderProducesGroupReorderPlan() throws {
        let groupId = UUID()
        let otherGroupId = UUID()
        let otherAnchorId = UUID()
        let outsideWorkspaceId = UUID()
        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 12, y: 64),
                draggedWorkspaceId: groupId,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: outsideWorkspaceId,
                        isPinned: false,
                        groupId: nil
                    ),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: groupId,
                        anchorWorkspaceId: groupId,
                        isPinned: true,
                        isEmpty: true
                    ),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: otherGroupId,
                        anchorWorkspaceId: otherAnchorId,
                        isPinned: true
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: groupId,
                        groupId: groupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: otherAnchorId,
                        groupId: otherGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 40, width: 180, height: 32)
                    ),
                ]
            )
        ))

        guard case .reorderGroup(let targetIndex) = plan.action else {
            Issue.record("expected a group-slot reorder")
            return
        }
        #expect(targetIndex == 1)
        #expect(plan.draggedWorkspaceId == groupId)
    }

    @Test func droppingIntoEmptyGroupPreservesHeaderSlot() throws {
        let groupId = UUID()
        let headerId = groupId
        let beforeId = UUID()
        let draggedId = UUID()
        let afterId = UUID()
        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 12, y: 56),
                draggedWorkspaceId: draggedId,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: beforeId, isPinned: false, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: draggedId, isPinned: false, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: afterId, isPinned: false, groupId: nil),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: groupId,
                        anchorWorkspaceId: headerId,
                        isPinned: false,
                        isEmpty: true
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: beforeId,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: headerId,
                        groupId: groupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 40, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: afterId,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 80, width: 180, height: 32)
                    ),
                ]
            )
        ))

        guard case .reorder(let targetIndex, _, let explicitGroupId) = plan.action else {
            Issue.record("expected a workspace reorder into the empty group")
            return
        }
        #expect(targetIndex == 1)
        #expect(explicitGroupId == groupId)
    }

    @Test func rootDropBeforeEmptyHeaderProducesPlan() throws {
        let groupId = UUID()
        let draggedId = UUID()
        let outsideId = UUID()
        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 12, y: 88),
                draggedWorkspaceId: draggedId,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: draggedId, isPinned: false, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: outsideId, isPinned: false, groupId: nil),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: groupId,
                        anchorWorkspaceId: groupId,
                        isPinned: false,
                        isEmpty: true
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: draggedId,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: outsideId,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 40, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: groupId,
                        groupId: groupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 80, width: 180, height: 32)
                    ),
                ]
            )
        ))

        guard case .reorder(_, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("expected a root workspace reorder")
            return
        }
        #expect(usesTopLevelRows)
        #expect(explicitGroupId == nil)
        #expect(plan.indicator?.tabId == groupId)
        #expect(plan.indicator?.edge == .top)
    }

    @Test func emptyHeaderDragAtRootBoundaryUsesFollowingGroupSlot() throws {
        let emptyGroupId = UUID()
        let liveGroupId = UUID()
        let liveAnchorId = UUID()
        let liveMemberId = UUID()
        let rootId = UUID()
        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 12, y: 128),
                draggedWorkspaceId: emptyGroupId,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: liveAnchorId, isPinned: false, groupId: liveGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: liveMemberId, isPinned: false, groupId: liveGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: rootId, isPinned: false, groupId: nil),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: emptyGroupId,
                        anchorWorkspaceId: emptyGroupId,
                        isPinned: false,
                        isEmpty: true
                    ),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: liveGroupId,
                        anchorWorkspaceId: liveAnchorId,
                        isPinned: false
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: emptyGroupId,
                        groupId: emptyGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: liveAnchorId,
                        groupId: liveGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 40, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: liveMemberId,
                        groupId: liveGroupId,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 80, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: rootId,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 120, width: 180, height: 32)
                    ),
                ]
            )
        ))

        guard case .reorderGroup(let targetIndex) = plan.action else {
            Issue.record("expected an empty-group slot move")
            return
        }
        #expect(targetIndex == 1)
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
