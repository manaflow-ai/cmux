@testable import CmuxNextSidebar
import Testing

/// The groups a close of several selected rows empties (`SidebarModel.groupsEmptied`), which then close
/// as Close Group does instead of staying behind empty (`WorkspaceSelectionClose`).
@MainActor
struct SidebarSelectionCloseTests {
    private static let ids = (0..<5).map { WorkspaceID("workspace-\($0)") }

    /// Rows 0 and 1 in group "a", row 2 in group "b", rows 3 and 4 loose.
    private static func model(items: [SidebarGroupItem] = []) -> SidebarModel {
        let rows = ids.enumerated().map { SidebarWorkspace(id: $0.element, title: "Workspace \($0.offset)") }
        var first = SidebarGroup(id: GroupID("a"), name: "A", workspaces: [rows[0], rows[1]])
        first.items = items
        let second = SidebarGroup(id: GroupID("b"), name: "B", workspaces: [rows[2]])
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes: [SidebarNode] = [.group(first), .group(second), .workspace(rows[3]), .workspace(rows[4])]
        return SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: ids[0])
    }

    @Test func aGroupEveryClosedRowEmptiesIsEmptied() {
        #expect(Self.model().groupsEmptied(byClosing: [Self.ids[0], Self.ids[1], Self.ids[3]]).map(\.id) == [GroupID("a")])
    }

    @Test func aGroupWithARowLeftOpenStays() {
        #expect(Self.model().groupsEmptied(byClosing: [Self.ids[1], Self.ids[2]]).map(\.id) == [GroupID("b")])
    }

    @Test func aGroupWithALinkLeftStays() {
        let link = SidebarListItem(id: "item-1", ref: LayoutItemRef(kind: "url", value: "https://example.com"), title: "Example")
        #expect(Self.model(items: [SidebarGroupItem(item: link, after: Self.ids[0])]).groupsEmptied(byClosing: [Self.ids[0], Self.ids[1]]).isEmpty)
    }

    @Test func looseRowsEmptyNoGroup() {
        #expect(Self.model().groupsEmptied(byClosing: [Self.ids[3], Self.ids[4]]).isEmpty)
    }

    @Test func everyGroupASelectionEmptiesIsListedInSidebarOrder() {
        #expect(Self.model().groupsEmptied(byClosing: Self.ids.reversed()).map(\.id) == [GroupID("a"), GroupID("b")])
    }
}
