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

    @Test func ungroupedWorkspaceEdgeDropOverNestedGroupHeaderTargetsParentGroup() throws {
        let rootGroupId = UUID()
        let childGroupId = UUID()
        let rootAnchor = UUID()
        let childAnchor = UUID()
        let childMember = UUID()
        let dragged = UUID()
        let outside = UUID()

        func plan(at point: CGPoint) throws -> SidebarWorkspaceReorderDropPlan {
            try #require(SidebarWorkspaceReorderDropResolver().plan(
                for: SidebarWorkspaceReorderDropRequest(
                    point: point,
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
        }

        let edgePlan = try plan(at: CGPoint(x: 12, y: 44))

        #expect(edgePlan.indicator == SidebarDropIndicator(tabId: childAnchor, edge: .top))
        #expect(edgePlan.indicatorScope == .group(rootGroupId))
        guard case .reorder(let edgeTargetIndex, let edgeUsesTopLevelRows, let edgeExplicitGroupId) = edgePlan.action else {
            Issue.record("Expected parent-group reorder plan")
            return
        }
        #expect(edgeTargetIndex == 1)
        #expect(!edgeUsesTopLevelRows)
        #expect(edgeExplicitGroupId == rootGroupId)

        let centerPlan = try plan(at: CGPoint(x: 12, y: 56))

        #expect(centerPlan.indicator == SidebarDropIndicator(tabId: childAnchor, edge: .bottom))
        #expect(centerPlan.indicatorScope == .group(childGroupId))
        guard case .reorder(let centerTargetIndex, let centerUsesTopLevelRows, let centerExplicitGroupId) = centerPlan.action else {
            Issue.record("Expected child-group reorder plan")
            return
        }
        #expect(centerTargetIndex == 2)
        #expect(!centerUsesTopLevelRows)
        #expect(centerExplicitGroupId == childGroupId)
    }

    @Test func draggingNestedGroupAnchorToRootEndProducesPromotionPlan() throws {
        let parentGroupId = UUID()
        let childGroupId = UUID()
        let parentAnchor = UUID()
        let childAnchor = UUID()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 0, y: 96),
                draggedWorkspaceId: childAnchor,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: parentAnchor, isPinned: false, groupId: parentGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childAnchor, isPinned: false, groupId: childGroupId),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(id: parentGroupId, anchorWorkspaceId: parentAnchor, isPinned: false),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: childGroupId,
                        anchorWorkspaceId: childAnchor,
                        isPinned: false,
                        parentGroupId: parentGroupId
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: parentAnchor,
                        groupId: parentGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: childAnchor,
                        groupId: childGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 12, y: 40, width: 168, height: 32)
                    ),
                ]
            )
        ))

        #expect(plan.indicator == SidebarDropIndicator(tabId: nil, edge: .bottom))
        #expect(plan.indicatorScope == .topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected top-level reorder plan")
            return
        }
        #expect(targetIndex == 1)
        #expect(usesTopLevelRows)
        #expect(explicitGroupId == nil)
    }

    @Test func nestedChildFolderTopEdgeTargetsParentGroupSiblingScope() throws {
        let parentGroupId = UUID()
        let childGroupId = UUID()
        let parentAnchor = UUID()
        let childAnchor = UUID()
        let childMember = UUID()
        let dragged = UUID()
        let outside = UUID()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: nestedFolderRequest(
                point: CGPoint(x: 20, y: 44),
                parentGroupId: parentGroupId,
                childGroupId: childGroupId,
                parentAnchor: parentAnchor,
                childAnchor: childAnchor,
                childMember: childMember,
                dragged: dragged,
                outside: outside,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: parentAnchor, isPinned: false, groupId: parentGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childAnchor, isPinned: false, groupId: childGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childMember, isPinned: false, groupId: childGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: dragged, isPinned: false, groupId: parentGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: outside, isPinned: false, groupId: nil),
                ]
            )
        ))

        #expect(plan.indicator == SidebarDropIndicator(tabId: childAnchor, edge: .top))
        #expect(plan.indicatorScope == .group(parentGroupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected parent-group reorder plan")
            return
        }
        #expect(targetIndex == 1)
        #expect(!usesTopLevelRows)
        #expect(explicitGroupId == parentGroupId)
    }

    @Test func nestedChildFolderBottomEdgeTargetsParentGroupSiblingScope() throws {
        let parentGroupId = UUID()
        let childGroupId = UUID()
        let parentAnchor = UUID()
        let childAnchor = UUID()
        let childMember = UUID()
        let dragged = UUID()
        let outside = UUID()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: nestedFolderRequest(
                point: CGPoint(x: 120, y: 68),
                parentGroupId: parentGroupId,
                childGroupId: childGroupId,
                parentAnchor: parentAnchor,
                childAnchor: childAnchor,
                childMember: childMember,
                dragged: dragged,
                outside: outside,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: parentAnchor, isPinned: false, groupId: parentGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: dragged, isPinned: false, groupId: parentGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childAnchor, isPinned: false, groupId: childGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childMember, isPinned: false, groupId: childGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: outside, isPinned: false, groupId: nil),
                ]
            )
        ))

        #expect(plan.indicator == SidebarDropIndicator(tabId: childAnchor, edge: .bottom))
        #expect(plan.indicatorScope == .group(parentGroupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected parent-group reorder plan")
            return
        }
        #expect(targetIndex == 2)
        #expect(!usesTopLevelRows)
        #expect(explicitGroupId == parentGroupId)
    }

    @Test func nestedFolderAnchorEdgesTargetParentGroupSiblingScope() throws {
        let parentGroupId = UUID()
        let draggedGroupId = UUID()
        let siblingGroupId = UUID()
        let parentAnchor = UUID()
        let draggedAnchor = UUID()
        let draggedMember = UUID()
        let siblingAnchor = UUID()
        let siblingMember = UUID()
        let outside = UUID()

        func request(point: CGPoint, draggedWorkspaceId: UUID) -> SidebarWorkspaceReorderDropRequest {
            SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: draggedWorkspaceId,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: parentAnchor, isPinned: false, groupId: parentGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: draggedAnchor, isPinned: false, groupId: draggedGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: draggedMember, isPinned: false, groupId: draggedGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: siblingAnchor, isPinned: false, groupId: siblingGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: siblingMember, isPinned: false, groupId: siblingGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: outside, isPinned: false, groupId: nil),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(id: parentGroupId, anchorWorkspaceId: parentAnchor, isPinned: false),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: draggedGroupId,
                        anchorWorkspaceId: draggedAnchor,
                        isPinned: false,
                        parentGroupId: parentGroupId
                    ),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: siblingGroupId,
                        anchorWorkspaceId: siblingAnchor,
                        isPinned: false,
                        parentGroupId: parentGroupId
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: parentAnchor,
                        groupId: parentGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: draggedAnchor,
                        groupId: draggedGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 12, y: 40, width: 168, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: draggedMember,
                        groupId: draggedGroupId,
                        isGroupHeader: false,
                        frame: CGRect(x: 24, y: 80, width: 156, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: siblingAnchor,
                        groupId: siblingGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 12, y: 120, width: 168, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: siblingMember,
                        groupId: siblingGroupId,
                        isGroupHeader: false,
                        frame: CGRect(x: 24, y: 160, width: 156, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: outside,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 200, width: 180, height: 32)
                    ),
                ]
            )
        }

        let topPlan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: request(point: CGPoint(x: 20, y: 124), draggedWorkspaceId: draggedAnchor)
        ))
        #expect(topPlan.indicator == SidebarDropIndicator(tabId: siblingAnchor, edge: .top))
        assertParentGroupPlan(topPlan, parentGroupId: parentGroupId, targetIndex: 2)

        let bottomPlan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: request(point: CGPoint(x: 20, y: 148), draggedWorkspaceId: draggedAnchor)
        ))
        #expect(bottomPlan.indicator == SidebarDropIndicator(tabId: siblingAnchor, edge: .bottom))
        assertParentGroupPlan(bottomPlan, parentGroupId: parentGroupId, targetIndex: 3)

        let memberPlan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: request(point: CGPoint(x: 20, y: 124), draggedWorkspaceId: draggedMember)
        ))
        #expect(memberPlan.indicator == SidebarDropIndicator(tabId: siblingAnchor, edge: .top))
        assertParentGroupPlan(memberPlan, parentGroupId: parentGroupId, targetIndex: 2)
    }

    @Test func nestedFolderAnchorEdgeAcrossParentsDoesNotTargetOtherParentGroup() throws {
        let sourceParentId = UUID()
        let draggedGroupId = UUID()
        let targetParentId = UUID()
        let targetGroupId = UUID()
        let sourceParentAnchor = UUID()
        let draggedAnchor = UUID()
        let targetParentAnchor = UUID()
        let targetAnchor = UUID()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 20, y: 124),
                draggedWorkspaceId: draggedAnchor,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: sourceParentAnchor, isPinned: false, groupId: sourceParentId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: draggedAnchor, isPinned: false, groupId: draggedGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: targetParentAnchor, isPinned: false, groupId: targetParentId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: targetAnchor, isPinned: false, groupId: targetGroupId),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(id: sourceParentId, anchorWorkspaceId: sourceParentAnchor, isPinned: false),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: draggedGroupId,
                        anchorWorkspaceId: draggedAnchor,
                        isPinned: false,
                        parentGroupId: sourceParentId
                    ),
                    SidebarWorkspaceReorderGroupSnapshot(id: targetParentId, anchorWorkspaceId: targetParentAnchor, isPinned: false),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: targetGroupId,
                        anchorWorkspaceId: targetAnchor,
                        isPinned: false,
                        parentGroupId: targetParentId
                    ),
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: sourceParentAnchor,
                        groupId: sourceParentId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: draggedAnchor,
                        groupId: draggedGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 12, y: 40, width: 168, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: targetParentAnchor,
                        groupId: targetParentId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 80, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: targetAnchor,
                        groupId: targetGroupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 12, y: 120, width: 168, height: 32)
                    ),
                ]
            )
        ))

        guard case .reorder(_, _, let explicitGroupId) = plan.action else {
            return
        }
        #expect(explicitGroupId != targetParentId)
    }

    private func assertParentGroupPlan(
        _ plan: SidebarWorkspaceReorderDropPlan,
        parentGroupId: UUID,
        targetIndex: Int
    ) {
        #expect(plan.indicatorScope == .group(parentGroupId))
        guard case .reorder(let resolvedTargetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected parent-group reorder plan")
            return
        }
        #expect(resolvedTargetIndex == targetIndex)
        #expect(!usesTopLevelRows)
        #expect(explicitGroupId == parentGroupId)
    }

    private func nestedFolderRequest(
        point: CGPoint,
        parentGroupId: UUID,
        childGroupId: UUID,
        parentAnchor: UUID,
        childAnchor: UUID,
        childMember: UUID,
        dragged: UUID,
        outside: UUID,
        workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot]
    ) -> SidebarWorkspaceReorderDropRequest {
        SidebarWorkspaceReorderDropRequest(
            point: point,
            draggedWorkspaceId: dragged,
            workspaces: workspaces,
            groups: [
                SidebarWorkspaceReorderGroupSnapshot(id: parentGroupId, anchorWorkspaceId: parentAnchor, isPinned: false),
                SidebarWorkspaceReorderGroupSnapshot(
                    id: childGroupId,
                    anchorWorkspaceId: childAnchor,
                    isPinned: false,
                    parentGroupId: parentGroupId
                ),
            ],
            targets: [
                SidebarWorkspaceReorderDropTarget(
                    workspaceId: parentAnchor,
                    groupId: parentGroupId,
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
                    workspaceId: outside,
                    groupId: nil,
                    isGroupHeader: false,
                    frame: CGRect(x: 0, y: 120, width: 180, height: 32)
                ),
            ]
        )
    }
}
