import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SidebarDropPlannerPackageTests {
    @Test func destinationPinStateFollowsTargetTierAndTailSemantics() {
        let pinned = UUID()
        let dragged = UUID()
        let unpinned = UUID()
        let ids = [pinned, dragged, unpinned]
        let pinnedIds: Set<UUID> = [pinned, dragged]
        let planner = SidebarDropPlanner()

        #expect(planner.destinationPinnedState(
            draggedTabId: dragged,
            targetTabId: unpinned,
            tabIds: ids,
            pinnedTabIds: pinnedIds
        ) == false)
        #expect(planner.destinationPinnedState(
            draggedTabId: unpinned,
            targetTabId: pinned,
            tabIds: ids,
            pinnedTabIds: pinnedIds
        ) == true)
        #expect(planner.destinationPinnedState(
            draggedTabId: dragged,
            targetTabId: nil,
            tabIds: ids,
            pinnedTabIds: pinnedIds
        ) == false)
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

    @Test func unpinnedGroupedChildDroppedAbovePinnedRowsUsesTopPointerSlot() throws {
        let fixture = PinnedBoundaryFixture()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 1))
        ))

        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        #expect(targetIndex == 0)
        #expect(usesTopLevelRows)
        #expect(explicitGroupId == nil)
        #expect(plan.targetPinnedState == true)
    }

    @Test func unpinnedGroupedChildDroppedAboveSecondPinnedRowUsesSecondPointerSlot() throws {
        let fixture = PinnedBoundaryFixture()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 41))
        ))

        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        #expect(targetIndex == 1)
        #expect(usesTopLevelRows)
        #expect(explicitGroupId == nil)
        #expect(plan.targetPinnedState == true)
    }

    @Test func pinnedWorkspaceDroppedAtFirstUnpinnedSlotProducesPinOnlyPlan() throws {
        let firstPinned = UUID()
        let draggedPinned = UUID()
        let firstUnpinned = UUID()
        let workspaces = [
            SidebarWorkspaceReorderWorkspaceSnapshot(id: firstPinned, isPinned: true, groupId: nil),
            SidebarWorkspaceReorderWorkspaceSnapshot(id: draggedPinned, isPinned: true, groupId: nil),
            SidebarWorkspaceReorderWorkspaceSnapshot(id: firstUnpinned, isPinned: false, groupId: nil),
        ]
        let request = SidebarWorkspaceReorderDropRequest(
            point: CGPoint(x: 2, y: 81),
            draggedWorkspaceId: draggedPinned,
            workspaces: workspaces,
            groups: [],
            targets: workspaces.enumerated().map { index, workspace in
                SidebarWorkspaceReorderDropTarget(
                    workspaceId: workspace.id,
                    groupId: nil,
                    isGroupHeader: false,
                    frame: CGRect(x: 0, y: CGFloat(index * 40), width: 180, height: 32)
                )
            }
        )

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(for: request))

        #expect(plan.indicator == SidebarDropIndicator(tabId: firstUnpinned, edge: .top))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        #expect(targetIndex == 1)
        #expect(!usesTopLevelRows)
        #expect(explicitGroupId == nil)
        #expect(plan.targetPinnedState == false)
    }

    @Test func unpinnedLastWorkspaceDroppedInTailBlankSpaceKeepsPinState() {
        let pinnedWorkspace = UUID()
        let draggedUnpinnedWorkspace = UUID()
        let workspaces = [
            SidebarWorkspaceReorderWorkspaceSnapshot(id: pinnedWorkspace, isPinned: true, groupId: nil),
            SidebarWorkspaceReorderWorkspaceSnapshot(
                id: draggedUnpinnedWorkspace,
                isPinned: false,
                groupId: nil
            ),
        ]
        let request = SidebarWorkspaceReorderDropRequest(
            point: CGPoint(x: 2, y: 100),
            draggedWorkspaceId: draggedUnpinnedWorkspace,
            workspaces: workspaces,
            groups: [],
            targets: workspaces.enumerated().map { index, workspace in
                SidebarWorkspaceReorderDropTarget(
                    workspaceId: workspace.id,
                    groupId: nil,
                    isGroupHeader: false,
                    frame: CGRect(x: 0, y: CGFloat(index * 40), width: 180, height: 32)
                )
            }
        )

        let plan = SidebarWorkspaceReorderDropResolver().plan(for: request)

        #expect(plan == nil)
    }

    @Test func unpinnedRootDroppedBelowPinnedRootsCountsPinnedGroupRows() throws {
        let groupId = UUID()
        let groupAnchor = UUID()
        let groupChild = UUID()
        let firstPinnedRoot = UUID()
        let secondPinnedRoot = UUID()
        let draggedUnpinnedRoot = UUID()
        let workspaces = [
            SidebarWorkspaceReorderWorkspaceSnapshot(id: groupAnchor, isPinned: false, groupId: groupId),
            SidebarWorkspaceReorderWorkspaceSnapshot(id: groupChild, isPinned: false, groupId: groupId),
            SidebarWorkspaceReorderWorkspaceSnapshot(id: firstPinnedRoot, isPinned: true, groupId: nil),
            SidebarWorkspaceReorderWorkspaceSnapshot(id: secondPinnedRoot, isPinned: true, groupId: nil),
            SidebarWorkspaceReorderWorkspaceSnapshot(id: draggedUnpinnedRoot, isPinned: false, groupId: nil),
        ]
        let request = SidebarWorkspaceReorderDropRequest(
            point: CGPoint(x: 2, y: 150),
            draggedWorkspaceId: draggedUnpinnedRoot,
            workspaces: workspaces,
            groups: [
                SidebarWorkspaceReorderGroupSnapshot(
                    id: groupId,
                    anchorWorkspaceId: groupAnchor,
                    isPinned: true
                ),
            ],
            targets: workspaces.enumerated().map { index, workspace in
                SidebarWorkspaceReorderDropTarget(
                    workspaceId: workspace.id,
                    groupId: workspace.groupId,
                    isGroupHeader: workspace.id == groupAnchor,
                    frame: CGRect(x: 0, y: CGFloat(index * 40), width: 180, height: 32)
                )
            }
        )

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(for: request))

        #expect(plan.indicator == SidebarDropIndicator(tabId: secondPinnedRoot, edge: .bottom))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        #expect(targetIndex == 4)
        #expect(!usesTopLevelRows)
        #expect(explicitGroupId == nil)
        #expect(plan.targetPinnedState == true)
    }

    private struct PinnedBoundaryFixture {
        let firstPinned = UUID()
        let secondPinned = UUID()
        let thirdPinned = UUID()
        let groupAnchor = UUID()
        let draggedChild = UUID()
        let unpinnedRoot = UUID()
        let groupId = UUID()

        func request(point: CGPoint) -> SidebarWorkspaceReorderDropRequest {
            let rows: [(UUID, UUID?, Bool)] = [
                (firstPinned, nil, false),
                (secondPinned, nil, false),
                (thirdPinned, nil, false),
                (groupAnchor, groupId, true),
                (draggedChild, groupId, false),
                (unpinnedRoot, nil, false),
            ]
            return SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: draggedChild,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: firstPinned, isPinned: true, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: secondPinned, isPinned: true, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: thirdPinned, isPinned: true, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: groupAnchor, isPinned: false, groupId: groupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: draggedChild, isPinned: false, groupId: groupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: unpinnedRoot, isPinned: false, groupId: nil),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: groupId,
                        anchorWorkspaceId: groupAnchor,
                        isPinned: false
                    ),
                ],
                targets: rows.enumerated().map { index, row in
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: row.0,
                        groupId: row.1,
                        isGroupHeader: row.2,
                        frame: CGRect(x: 0, y: CGFloat(index * 40), width: 180, height: 32)
                    )
                }
            )
        }
    }
}
