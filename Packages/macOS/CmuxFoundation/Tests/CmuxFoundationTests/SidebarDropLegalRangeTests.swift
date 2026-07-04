import CoreGraphics
import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SidebarDropLegalRangeTests {
    @Test func unpinnedWorkspaceDropClampsAfterPinnedChildFolderSubtree() throws {
        let parentGroupId = UUID()
        let childGroupId = UUID()
        let parentAnchor = UUID()
        let childAnchor = UUID()
        let childMember = UUID()
        let dragged = UUID()

        let plan = try #require(SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: CGPoint(x: 20, y: 44),
                draggedWorkspaceId: dragged,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: parentAnchor, isPinned: false, groupId: parentGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childAnchor, isPinned: false, groupId: childGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childMember, isPinned: false, groupId: childGroupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: dragged, isPinned: false, groupId: nil),
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(id: parentGroupId, anchorWorkspaceId: parentAnchor, isPinned: false),
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: childGroupId,
                        anchorWorkspaceId: childAnchor,
                        isPinned: true,
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
                        workspaceId: dragged,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 120, width: 180, height: 32)
                    ),
                ]
            )
        ))

        #expect(plan.indicator == SidebarDropIndicator(tabId: childMember, edge: .bottom))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected parent-group reorder plan")
            return
        }
        #expect(targetIndex == 3)
        #expect(!usesTopLevelRows)
        #expect(explicitGroupId == parentGroupId)
    }
}
