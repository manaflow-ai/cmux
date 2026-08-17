import Foundation
import Testing

@testable import CmuxWorkspaces

/// Block (multi-selection) drops scoped inside a workspace group section,
/// mirroring `SidebarWorkspaceReorderDropResolver.groupScopedPlan`: full row
/// space, removal-adjusted target index, and an explicit group id.
@MainActor
struct WorkspaceCoordinatorGroupBlockTests {
    private func makeWorld() -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        host: StubGroupHost,
        groups: WorkspaceGroupCoordinator<CoordinatorStubTab>,
        reorder: WorkspaceReorderCoordinator<CoordinatorStubTab>
    ) {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        return (model, host, groups, reorder)
    }

    /// Group of four members plus two loose rows below the section:
    /// `[anchor, m1, m2, m3, m4, l1, l2]`.
    private func makeGroupWorld() throws -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        host: StubGroupHost,
        reorder: WorkspaceReorderCoordinator<CoordinatorStubTab>,
        groupId: UUID,
        anchorId: UUID,
        m1: CoordinatorStubTab,
        m2: CoordinatorStubTab,
        m3: CoordinatorStubTab,
        m4: CoordinatorStubTab,
        l1: CoordinatorStubTab,
        l2: CoordinatorStubTab
    ) {
        let (model, host, groups, reorder) = makeWorld()
        let m1 = CoordinatorStubTab()
        let m2 = CoordinatorStubTab()
        let m3 = CoordinatorStubTab()
        let m4 = CoordinatorStubTab()
        let l1 = CoordinatorStubTab()
        let l2 = CoordinatorStubTab()
        model.tabs = [m1, m2, m3, m4, l1, l2]
        let groupId = try #require(groups.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [m1.id, m2.id, m3.id, m4.id]
        ))
        let anchorId = try #require(model.workspaceGroups.first?.anchorWorkspaceId)
        try #require(model.tabs.map(\.id) == [anchorId, m1.id, m2.id, m3.id, m4.id, l1.id, l2.id])
        return (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2)
    }

    @Test
    func inGroupBlockDropLandsAtMemberGap() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed m1 with {m1, m3} selected; drop at the gap above m4
        // (index 3 in the order without m1, clamped inside the section).
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m1.id, m3.id],
            draggedTabId: m1.id,
            toIndex: 3,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m2.id, m1.id, m3.id, m4.id, l1.id, l2.id])
        #expect(m1.groupId == groupId)
        #expect(m3.groupId == groupId)
    }

    @Test
    func inGroupBlockHopsOverNextMember() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed m1 with {m1, m2} selected; drop at the gap above m4: the
        // block hops over m3 together.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m1.id, m2.id],
            draggedTabId: m1.id,
            toIndex: 3,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m3.id, m1.id, m2.id, m4.id, l1.id, l2.id])
    }

    @Test
    func inGroupBlockDropAtSectionBottomGap() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed m1 with {m1, m3} selected; drop at the section's bottom gap
        // (below m4, group lane): index 4 in the order without m1.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m1.id, m3.id],
            draggedTabId: m1.id,
            toIndex: 4,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m2.id, m4.id, m1.id, m3.id, l1.id, l2.id])
        #expect(m1.groupId == groupId)
        #expect(m3.groupId == groupId)
    }

    @Test
    func inGroupBlockDropAtSectionTopGap() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed m3 with {m3, m4} selected; drop just below the anchor
        // (index 1 in the order without m3).
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m3.id, m4.id],
            draggedTabId: m3.id,
            toIndex: 1,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m3.id, m4.id, m1.id, m2.id, l1.id, l2.id])
    }

    @Test
    func inGroupAdjacentBlockDropAtOwnBoundaryIsAcceptedNoOp() throws {
        let (model, host, reorder, groupId, _, m1, m2, m3, _, _, _) = try makeGroupWorld()
        _ = m3

        // Grabbed m1 with {m1, m2} selected; drop at the gap directly below
        // the block (between m2 and m3). With the block removed that gap is
        // where the block already sits, so the order is unchanged — but the
        // drop was still accepted at a painted gap and must report success,
        // not a refusal (a false here makes AppKit animate a snap-back).
        let before = model.tabs.map(\.id)
        let orderChangesBefore = host.orderChanges.count
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [m1.id, m2.id],
            draggedTabId: m1.id,
            toIndex: 2,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == before)
        #expect(host.orderChanges.count == orderChangesBefore)
    }

    @Test
    func blockSpanningGroupBoundaryJoinsGroupOnExplicitDrop() throws {
        let (model, host, reorder, groupId, anchorId, m1, m2, m3, m4, l1, l2) = try makeGroupWorld()
        _ = host

        // Grabbed l1 with {l1, m2} selected; drop at the gap above m4 inside
        // the section (index 4 in the order without l1): the block lands
        // there in sidebar order (m2 before l1) and l1 joins the group.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [l1.id, m2.id],
            draggedTabId: l1.id,
            toIndex: 4,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(model.tabs.map(\.id) == [anchorId, m1.id, m3.id, m2.id, l1.id, m4.id, l2.id])
        #expect(l1.groupId == groupId)
        #expect(m2.groupId == groupId)
    }
}
