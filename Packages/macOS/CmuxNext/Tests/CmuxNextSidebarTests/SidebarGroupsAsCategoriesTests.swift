import AppKit
import Testing
@testable import CmuxNextSidebar

/// Leo (2026-10-06): your own groups are categories, as in Discord. They sit
/// above the built-in section, which is titled "All" while groups exist and
/// "Projects" otherwise. Rows keep their model indices, so drops resolve as before.
@MainActor @Suite struct SidebarGroupsAsCategoriesTests {
    private let local = SidebarMachine(id: .local, name: "Local", kind: .local)

    private func sections(groups: Bool) -> [SidebarSection] {
        var nodes: [SidebarNode] = [.workspace(w("a"))]
        if groups { nodes.append(.group(SidebarGroup(id: GroupID("g"), name: "Work", color: .blue, workspaces: [w("b"), w("c")]))) }
        nodes.append(.workspace(w("d")))
        return [SidebarSection(kind: .machine(local), nodes: nodes)]
    }

    private func layout(_ sections: [SidebarSection]) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.showsSoleMachineHeader = true
        options.groupsAsCategories = true
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options)
    }

    @Test func groupsSitAboveTheBuiltInSectionTitledAll() {
        let rows = layout(sections(groups: true)).rows
        #expect(rows.map(\.key) == [.group(GroupID("g")), .workspace(id("b")), .workspace(id("c")),
                                    .section(.machine(.local)), .workspace(id("a")), .workspace(id("d"))])
        let header = rows[3]
        #expect(header.titlesAll && header.childCount == 2)
        // Model indices are kept: the group is node 1, the loose rows 0 and 2.
        #expect(rows[0].siblingIndex == 1 && rows[4].siblingIndex == 0 && rows[5].siblingIndex == 2)
        #expect(rows.map(\.y) == rows.map(\.y).sorted())
    }

    @Test func withoutGroupsTheSectionIsProjects() {
        let rows = layout(sections(groups: false)).rows
        #expect(rows.first?.key == .section(.machine(.local)))
        #expect(rows.first?.titlesProjects == true && rows.first?.titlesAll == false)
    }

    @Test func collapsingAllKeepsTheGroups() {
        var collapsed = sections(groups: true)
        collapsed[0].isCollapsed = true
        #expect(layout(collapsed).rows.map(\.key) == [.group(GroupID("g")), .workspace(id("b")), .workspace(id("c")), .section(.machine(.local))])
    }

    @Test func theSidebarListsGroupsFirst() {
        let model = SidebarModel(sections: sections(groups: true))
        #expect(model.listOptions().groupsAsCategories)
        #expect(model.itemOrder.rows == [.workspace(id("b")), .workspace(id("c")), .workspace(id("a")), .workspace(id("d"))])
    }
}
