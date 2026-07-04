import Foundation
import Testing

@testable import CmuxWorkspaces

@MainActor
@Suite struct WorkspaceNestedPinnedOrderingTests {
    @Test func pinningUngroupedWorkspaceDoesNotSplitPinnedRootFolderSubtree() throws {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)

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
        groups.setWorkspaceGroupPinned(groupId: hotelsId, isPinned: true)
        let hotelsAnchorId = try #require(model.workspaceGroups.first { $0.id == hotelsId }?.anchorWorkspaceId)
        let marriottAnchorId = try #require(model.workspaceGroups.first { $0.id == marriottId }?.anchorWorkspaceId)

        reorder.setPinned(outside, pinned: true)

        #expect(model.workspaceGroups.first { $0.id == hotelsId }?.isPinned == true)
        #expect(model.workspaceGroups.first { $0.id == marriottId }?.isPinned == false)
        #expect(model.tabs.map(\.id) == [
            hotelsAnchorId,
            hotelsMember.id,
            marriottAnchorId,
            marriottMember.id,
            outside.id,
        ])
    }
}
