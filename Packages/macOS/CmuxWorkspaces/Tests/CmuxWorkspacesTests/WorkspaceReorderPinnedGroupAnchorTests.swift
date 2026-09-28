import Foundation
import Testing

@testable import CmuxWorkspaces

/// Regression coverage for #13417 / #13505: reordering the anchor of a pinned
/// group whose rows fill the whole sidebar must not trap in `Array.insert`.
@MainActor
@Suite("Workspace reorder: pinned group anchor")
struct WorkspaceReorderPinnedGroupAnchorTests {
    private struct Fixture {
        let model: WorkspacesModel<CoordinatorStubTab>
        let host: StubGroupHost
        let reorder: WorkspaceReorderCoordinator<CoordinatorStubTab>
        let anchorId: UUID
        let memberId: UUID
    }

    /// One pinned group, anchor + member, neither workspace individually
    /// pinned, and no rows outside the group.
    private func makeFixture() throws -> Fixture {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)

        let member = CoordinatorStubTab()
        model.tabs = [member]
        let groupId = try #require(groups.createWorkspaceGroup(
            name: "Pinned",
            childWorkspaceIds: [member.id]
        ))
        let anchorId = try #require(
            model.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId
        )
        groups.setWorkspaceGroupPinned(groupId: groupId, isPinned: true)
        try #require(model.tabs.map(\.id) == [anchorId, member.id])
        try #require(model.tabs.allSatisfy { !$0.isPinned })

        return Fixture(
            model: model,
            host: host,
            reorder: reorder,
            anchorId: anchorId,
            memberId: member.id
        )
    }

    @Test
    func clampedIndexStaysInsideTheArrayWhenEveryRowIsGroupPinned() throws {
        let fixture = try makeFixture()
        let anchor = try #require(fixture.model.tabs.first { $0.id == fixture.anchorId })

        for requested in [-1, 0, 1, 2, 99] {
            let clamped = fixture.model.clampedReorderIndex(for: anchor, targetIndex: requested)
            #expect(
                clamped < fixture.model.tabs.count,
                "requested \(requested) clamped to \(clamped) on \(fixture.model.tabs.count) rows"
            )
        }
    }

    @Test
    func reorderingThePinnedGroupAnchorToTheTopKeepsTheOrder() throws {
        let fixture = try makeFixture()
        let anchor = try #require(fixture.model.tabs.first { $0.id == fixture.anchorId })
        // Without the fix this reorder traps in Array.insert and takes the
        // whole test process down, so check the clamp before calling it.
        try #require(
            fixture.model.clampedReorderIndex(for: anchor, targetIndex: 0) < fixture.model.tabs.count
        )

        #expect(fixture.reorder.reorderWorkspace(tabId: fixture.anchorId, toIndex: 0))
        #expect(fixture.model.tabs.map(\.id) == [fixture.anchorId, fixture.memberId])
    }
}
