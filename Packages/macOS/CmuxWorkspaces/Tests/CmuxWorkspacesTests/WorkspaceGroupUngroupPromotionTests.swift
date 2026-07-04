import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class UngroupPromotionTab: WorkspaceTabRepresenting {
    let id = UUID()
    var groupId: UUID?
    var isPinned: Bool
    let currentDirectory = "/tmp"

    init(groupId: UUID?, isPinned: Bool = false) {
        self.groupId = groupId
        self.isPinned = isPinned
    }
}

@MainActor
@Suite struct WorkspaceGroupUngroupPromotionTests {
    @Test func ungroupRootNormalizesPinnedChildFolderPromotedToRoot() throws {
        let rootId = UUID()
        let childId = UUID()
        let rootAnchor = UngroupPromotionTab(groupId: rootId)
        let rootMember = UngroupPromotionTab(groupId: rootId)
        let childAnchor = UngroupPromotionTab(groupId: childId)
        let childMember = UngroupPromotionTab(groupId: childId)
        let model = WorkspacesModel<UngroupPromotionTab>()
        model.tabs = [
            rootAnchor,
            rootMember,
            childAnchor,
            childMember,
        ]
        model.workspaceGroups = [
            WorkspaceGroup(
                id: rootId,
                name: "Root",
                isCollapsed: false,
                isPinned: false,
                anchorWorkspaceId: rootAnchor.id,
                customColor: nil,
                iconSymbol: nil
            ),
            WorkspaceGroup(
                id: childId,
                name: "Child",
                isCollapsed: false,
                isPinned: true,
                parentGroupId: rootId,
                anchorWorkspaceId: childAnchor.id,
                customColor: nil,
                iconSymbol: nil
            ),
        ]
        let groups = WorkspaceGroupCoordinator(model: model)

        groups.ungroupWorkspaceGroup(groupId: rootId)

        let childGroup = try #require(model.workspaceGroups.first { $0.id == childId })
        #expect(childGroup.parentGroupId == nil)
        #expect(model.tabs.first?.id == childAnchor.id)
        #expect(model.sidebarTopLevelWorkspaceIds().first == childAnchor.id)
    }
}
