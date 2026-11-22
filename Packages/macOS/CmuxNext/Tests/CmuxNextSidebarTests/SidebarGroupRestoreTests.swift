import Testing
@testable import CmuxNextSidebar

/// RECOVERABLE-BY-DEFAULT (Lawrence + coordinator, 2026-10-06): Ungroup keeps
/// everything it takes away. The record captured before the ungroup brings
/// the group back with its name, color, collapse state, members and place.
@MainActor @Suite struct SidebarGroupRestoreTests {
    @Test func undoingAnUngroupRestoresNameColorCollapseMembersAndPlace() throws {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        let before = shape(model.sections, local)
        let restore = try #require(SidebarGroupRestore.capture(g2, in: model.sections))
        model.apply(.ungroup(g2))
        #expect(shape(model.sections, local) != before)

        let back = GroupID("G2-restored")
        model.apply(restore.intent(newID: back))
        let group = try #require(model.group(back))
        #expect(group.name == "G2")
        #expect(group.color == .green)
        #expect(group.isCollapsed)
        #expect(group.workspaces.map(\.id) == [id("h1"), id("h2")])
        #expect(shape(model.sections, local) == before.replacingOccurrences(of: "G2", with: "G2-restored"))
    }

    @Test func anExpandedGroupComesBackExpanded() throws {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        let restore = try #require(SidebarGroupRestore.capture(g1, in: model.sections))
        model.apply(.ungroup(g1))
        model.apply(restore.intent(newID: GroupID("G1b")))
        let group = try #require(model.group(GroupID("G1b")))
        #expect(!group.isCollapsed)
        #expect(group.color == .purple)
        #expect(group.workspaces.map(\.id) == [id("g1"), id("g2"), id("g3")])
    }

    @Test func aMissingGroupHasNoRecord() {
        #expect(SidebarGroupRestore.capture(GroupID("nope"), in: fixture()) == nil)
    }
}
