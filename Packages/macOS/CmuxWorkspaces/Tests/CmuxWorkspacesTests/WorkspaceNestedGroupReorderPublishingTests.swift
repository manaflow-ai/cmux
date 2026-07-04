import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
@Suite struct WorkspaceNestedGroupReorderPublishingTests {
    @Test func reorderingNestedGroupPublishesDescendantWorkspaceIds() throws {
        let (model, host, groups, reorder) = WorkspaceCoordinatorTests().makeWorld()
        let hotelsMember = CoordinatorStubTab()
        let marriottMember = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [hotelsMember, marriottMember, outside]
        let hotelsId = try #require(groups.createWorkspaceGroup(name: "Hotels", childWorkspaceIds: [hotelsMember.id]))
        let marriottId = try #require(groups.createWorkspaceGroup(
            name: "Marriott",
            childWorkspaceIds: [marriottMember.id],
            parentGroupId: hotelsId
        ))
        let marriottAnchorId = try #require(model.workspaceGroups.first { $0.id == marriottId }?.anchorWorkspaceId)

        #expect(reorder.reorderSidebarWorkspace(tabId: marriottAnchorId, toIndex: 1))

        #expect(Set(host.orderChanges.last ?? []) == Set([
            marriottAnchorId,
            marriottMember.id,
        ]))
    }
}
