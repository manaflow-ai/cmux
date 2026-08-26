import Foundation
import Testing

@testable import CmuxWorkspaces

/// Shared two-group world for top-level group-block reorder tests.
@MainActor
struct WorkspaceCoordinatorTopLevelGroupBlockFixture {
    let model: WorkspacesModel<CoordinatorStubTab>
    let host: StubGroupHost
    let groups: WorkspaceGroupCoordinator<CoordinatorStubTab>
    let reorder: WorkspaceReorderCoordinator<CoordinatorStubTab>
    let group1Id: UUID
    let group2Id: UUID
    let anchor1Id: UUID
    let anchor2Id: UUID
    let group1Child1: CoordinatorStubTab
    let group1Child2: CoordinatorStubTab
    let group2Child: CoordinatorStubTab
    let loose1: CoordinatorStubTab
    let loose2: CoordinatorStubTab
    let loose3: CoordinatorStubTab

    init() throws {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)

        let group1Child1 = CoordinatorStubTab()
        let group1Child2 = CoordinatorStubTab()
        let group2Child = CoordinatorStubTab()
        let loose1 = CoordinatorStubTab()
        let loose2 = CoordinatorStubTab()
        let loose3 = CoordinatorStubTab()
        model.tabs = [
            group1Child1,
            group1Child2,
            group2Child,
            loose1,
            loose2,
            loose3,
        ]
        let group1Id = try #require(groups.createWorkspaceGroup(
            name: "G1",
            childWorkspaceIds: [group1Child1.id, group1Child2.id]
        ))
        let group2Id = try #require(groups.createWorkspaceGroup(
            name: "G2",
            childWorkspaceIds: [group2Child.id]
        ))
        let anchor1Id = try #require(
            model.workspaceGroups.first { $0.id == group1Id }?.anchorWorkspaceId
        )
        let anchor2Id = try #require(
            model.workspaceGroups.first { $0.id == group2Id }?.anchorWorkspaceId
        )
        try #require(model.tabs.map(\.id) == [
            anchor1Id,
            group1Child1.id,
            group1Child2.id,
            anchor2Id,
            group2Child.id,
            loose1.id,
            loose2.id,
            loose3.id,
        ])

        self.model = model
        self.host = host
        self.groups = groups
        self.reorder = reorder
        self.group1Id = group1Id
        self.group2Id = group2Id
        self.anchor1Id = anchor1Id
        self.anchor2Id = anchor2Id
        self.group1Child1 = group1Child1
        self.group1Child2 = group1Child2
        self.group2Child = group2Child
        self.loose1 = loose1
        self.loose2 = loose2
        self.loose3 = loose3
    }
}
