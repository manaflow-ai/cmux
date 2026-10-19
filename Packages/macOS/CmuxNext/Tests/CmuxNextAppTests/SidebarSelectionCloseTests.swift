@testable import CmuxNextSidebar
import Testing

/// A close of several selected rows as one action (`SidebarModel.closePlan`, `closeTitle`).
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

    @Test func aGroupEveryClosedRowEmptiesClosesAsAGroup() {
        let plan = Self.model().closePlan([Self.ids[0], Self.ids[1], Self.ids[3]])
        #expect(plan.groups.map(\.id) == [GroupID("a")])
        #expect(plan.rows == [Self.ids[3]])
    }

    @Test func aGroupWithARowLeftOpenStays() {
        let plan = Self.model().closePlan([Self.ids[1], Self.ids[2]])
        #expect(plan.groups.map(\.id) == [GroupID("b")])
        #expect(plan.rows == [Self.ids[1]])
    }

    @Test func aGroupWithALinkLeftStays() {
        let link = SidebarListItem(id: "item-1", ref: LayoutItemRef(kind: "url", value: "https://example.com"), title: "Example")
        let plan = Self.model(items: [SidebarGroupItem(item: link, after: Self.ids[0])]).closePlan([Self.ids[0], Self.ids[1]])
        #expect(plan.groups.isEmpty)
        #expect(plan.rows == [Self.ids[0], Self.ids[1]])
    }

    @Test func closeTitleCountsTheSelection() {
        let model = Self.model()
        model.selection = [Self.ids[0], Self.ids[3], Self.ids[4]]
        #expect(model.closeTitle(for: Self.ids[3]) == "Close 3 Workspaces")
        #expect(model.closeTitle(for: Self.ids[1]) == nil)
    }

    @Test func closeTitleKeepsTheCatalogTitleForOneRow() {
        let model = Self.model()
        model.selection = [Self.ids[3]]
        #expect(model.closeTitle(for: Self.ids[3]) == nil)
    }
}
