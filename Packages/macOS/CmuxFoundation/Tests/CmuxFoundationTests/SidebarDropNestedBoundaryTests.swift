import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SidebarDropNestedBoundaryTests {
    @Test func childFolderMemberBottomEdgeOutdentTargetsParentGroupSiblingScope() throws {
        let parentGroupId = UUID()
        let childGroupId = UUID()
        let parentAnchor = UUID()
        let dragged = UUID()
        let childAnchor = UUID()
        let childMember = UUID()
        let outside = UUID()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: childFolderBoundaryRequest(
                point: CGPoint(x: 20, y: 108),
                parentGroupId: parentGroupId,
                childGroupId: childGroupId,
                parentAnchor: parentAnchor,
                dragged: dragged,
                childAnchor: childAnchor,
                childMember: childMember,
                outside: outside
            )
        ))

        #expect(plan.indicator == SidebarDropIndicator(tabId: childMember, edge: .bottom))
        #expect(plan.indicatorScope == .group(parentGroupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected parent-group reorder plan")
            return
        }
        #expect(targetIndex == 3)
        #expect(!usesTopLevelRows)
        #expect(explicitGroupId == parentGroupId)
    }

    @Test func childFolderMemberBottomEdgeAtChildIndentStaysInChildFolder() throws {
        let parentGroupId = UUID()
        let childGroupId = UUID()
        let parentAnchor = UUID()
        let dragged = UUID()
        let childAnchor = UUID()
        let childMember = UUID()
        let outside = UUID()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: childFolderBoundaryRequest(
                point: CGPoint(x: 120, y: 108),
                parentGroupId: parentGroupId,
                childGroupId: childGroupId,
                parentAnchor: parentAnchor,
                dragged: dragged,
                childAnchor: childAnchor,
                childMember: childMember,
                outside: outside
            )
        ))

        #expect(plan.indicator == SidebarDropIndicator(tabId: childMember, edge: .bottom))
        #expect(plan.indicatorScope == .group(childGroupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected child-group reorder plan")
            return
        }
        #expect(targetIndex == 3)
        #expect(!usesTopLevelRows)
        #expect(explicitGroupId == childGroupId)
    }

    private func childFolderBoundaryRequest(
        point: CGPoint,
        parentGroupId: UUID,
        childGroupId: UUID,
        parentAnchor: UUID,
        dragged: UUID,
        childAnchor: UUID,
        childMember: UUID,
        outside: UUID
    ) -> SidebarWorkspaceReorderDropRequest {
        SidebarWorkspaceReorderDropRequest(
            point: point,
            draggedWorkspaceId: dragged,
            workspaces: [
                SidebarWorkspaceReorderWorkspaceSnapshot(id: parentAnchor, isPinned: false, groupId: parentGroupId),
                SidebarWorkspaceReorderWorkspaceSnapshot(id: dragged, isPinned: false, groupId: parentGroupId),
                SidebarWorkspaceReorderWorkspaceSnapshot(id: childAnchor, isPinned: false, groupId: childGroupId),
                SidebarWorkspaceReorderWorkspaceSnapshot(id: childMember, isPinned: false, groupId: childGroupId),
                SidebarWorkspaceReorderWorkspaceSnapshot(id: outside, isPinned: false, groupId: nil),
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
