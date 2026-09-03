import Foundation
import Testing
@testable import CmuxWorkspaces

/// Close-path selection hand-off. The sidebar renders group anchors and
/// ungrouped workspaces as rows; a non-anchor member of a *collapsed* group has
/// no row of its own. Selecting such a member fires the selection auto-expand
/// (`expandWorkspaceGroupForSelectionIfNeeded`) and unfolds a group the user
/// deliberately collapsed, so the close path must never land there.
@MainActor
struct WorkspaceCloseSelectionTests {
    private func makeWorld() -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        host: StubGroupHost,
        groups: WorkspaceGroupCoordinator<CoordinatorStubTab>
    ) {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        return (model, host, groups)
    }

    /// Builds `[anchor, m1, m2, outside]`: one group run followed by a single
    /// ungrouped workspace, which is the ordering invariant's normal shape
    /// (groups above ungrouped-unpinned).
    ///
    /// The coordinator holds its host weakly, so callers must keep the returned
    /// `host` alive for the duration of the test.
    private func makeGroupAboveLoneWorkspace() throws -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        host: StubGroupHost,
        groups: WorkspaceGroupCoordinator<CoordinatorStubTab>,
        groupId: UUID,
        anchorId: UUID,
        m2: CoordinatorStubTab,
        outside: CoordinatorStubTab
    ) {
        let (model, host, groups) = makeWorld()
        let m1 = CoordinatorStubTab()
        let m2 = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [m1, m2, outside]
        let groupId = try #require(
            groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [m1.id, m2.id])
        )
        let anchorId = try #require(
            model.workspaceGroups.first(where: { $0.id == groupId })?.anchorWorkspaceId
        )
        #expect(model.tabs.map(\.id) == [anchorId, m1.id, m2.id, outside.id])
        return (model, host, groups, groupId, anchorId, m2, outside)
    }

    /// Closing the LAST workspace walks selection *backwards*, straight into the
    /// tail of the preceding group's member run. When that group is collapsed
    /// the tail member is invisible, so selection must land on the group's
    /// anchor (its visible header row) instead.
    @Test
    func closingLastWorkspaceSelectsAnchorNotHiddenMemberOfCollapsedGroup() throws {
        let world = try makeGroupAboveLoneWorkspace()
        world.groups.setWorkspaceGroupCollapsed(groupId: world.groupId, isCollapsed: true)

        let index = try #require(world.model.tabs.firstIndex(where: { $0.id == world.outside.id }))
        world.model.selectedTabId = world.outside.id
        world.model.tabs.remove(at: index)

        let target = try #require(world.model.selectionTargetAfterClose(closedIndex: index))
        #expect(target == world.anchorId)
        #expect(target != world.m2.id)
    }

    /// End-to-end consequence of the rule above: after the close path applies
    /// its selection and the selection side-effect chain runs, the group the
    /// user collapsed is still collapsed.
    @Test
    func closingLastWorkspaceKeepsPrecedingGroupCollapsed() throws {
        let world = try makeGroupAboveLoneWorkspace()
        world.groups.setWorkspaceGroupCollapsed(groupId: world.groupId, isCollapsed: true)

        let index = try #require(world.model.tabs.firstIndex(where: { $0.id == world.outside.id }))
        world.model.selectedTabId = world.outside.id
        world.model.tabs.remove(at: index)

        world.model.selectedTabId = world.model.selectionTargetAfterClose(closedIndex: index)
        // The model has no host attached here, so drive the selection
        // side-effect the window's `selectedTabId` didSet would have run.
        world.model.expandWorkspaceGroupForSelectionIfNeeded()

        #expect(world.model.workspaceGroups.first(where: { $0.id == world.groupId })?.isCollapsed == true)
    }

    /// Guard against over-correcting: an EXPANDED group's members do have their
    /// own sidebar rows, so selection keeps landing on the adjacent member and
    /// is not redirected to the anchor.
    @Test
    func closingLastWorkspaceSelectsAdjacentMemberOfExpandedGroup() throws {
        let world = try makeGroupAboveLoneWorkspace()

        let index = try #require(world.model.tabs.firstIndex(where: { $0.id == world.outside.id }))
        world.model.selectedTabId = world.outside.id
        world.model.tabs.remove(at: index)

        let target = try #require(world.model.selectionTargetAfterClose(closedIndex: index))
        #expect(target == world.m2.id)
    }

    /// Closing a non-last workspace still walks *forwards* into the workspace
    /// that moved up into the vacated slot.
    @Test
    func closingNonLastWorkspaceSelectsTheWorkspaceThatMovedUp() throws {
        let (model, host, _) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        model.tabs = [a, b, c]

        let index = try #require(model.tabs.firstIndex(where: { $0.id == b.id }))
        model.selectedTabId = b.id
        model.tabs.remove(at: index)

        let target = try #require(model.selectionTargetAfterClose(closedIndex: index))
        #expect(target == c.id)
    }
}
