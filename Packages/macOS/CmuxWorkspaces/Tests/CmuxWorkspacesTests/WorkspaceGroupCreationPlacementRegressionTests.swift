import Testing

@testable import CmuxWorkspaces

@MainActor
struct WorkspaceGroupCreationPlacementRegressionTests {
    @Test
    func emptyNestedWorkspaceGroupPreservesParentTopLevelPosition() throws {
        let (model, host, groups, _) = WorkspaceCoordinatorTests().makeWorld()
        _ = host
        let before = CoordinatorStubTab()
        let parentMember = CoordinatorStubTab()
        let after = CoordinatorStubTab()
        model.tabs = [before, parentMember, after]
        let parentId = try #require(groups.createWorkspaceGroup(
            name: "Parent",
            childWorkspaceIds: [parentMember.id],
            selectAnchor: false
        ))
        let parentAnchorId = try #require(model.workspaceGroups.first { $0.id == parentId }?.anchorWorkspaceId)
        #expect(model.sidebarTopLevelWorkspaceIds() == [before.id, parentAnchorId, after.id])

        let childId = try #require(groups.createWorkspaceGroup(
            name: "Child",
            parentGroupId: parentId,
            selectAnchor: false
        ))

        #expect(model.workspaceGroups.first { $0.id == childId }?.parentGroupId == parentId)
        #expect(model.sidebarTopLevelWorkspaceIds() == [before.id, parentAnchorId, after.id])
    }
}
