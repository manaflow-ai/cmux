import AppKit
import Testing
@testable import CmuxNextSidebar

/// With one machine the workspace list sits under a "Projects" header, so
/// Home and the App Store above it read as destinations, not workspaces.
/// A second machine brings back the machine names.
@MainActor @Suite struct SidebarProjectsHeaderTests {
    func list(_ sections: [SidebarSection]) -> SidebarListView {
        let sidebar = SidebarView(model: SidebarModel(sections: sections, activeWorkspaceID: id("a")))
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return sidebar.list
    }

    var localOnly: [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                        nodes: [.workspace(w("a")), .workspace(w("b"))])]
    }

    @Test func soleMachineListsUnderProjects() {
        let list = list(localOnly)
        #expect(list.displayed.rows.map(\.key) == [.section(local), .workspace(id("a")), .workspace(id("b"))])
        #expect(list.displayed.row(for: .section(local))?.titlesProjects == true)
        let header = list.rowViews[.section(local)] as? SectionHeaderRowView
        #expect(header?.accessibilityLabel() == "Projects")
    }

    @Test func projectsCollapses() {
        var sections = localOnly
        sections[0].isCollapsed = true
        #expect(list(sections).displayed.rows.map(\.key) == [.section(local)])
    }

    @Test func secondMachineKeepsMachineNames() {
        let list = list(fixture())
        #expect(list.displayed.row(for: .section(local))?.titlesProjects == false)
        #expect(list.displayed.row(for: .section(cloudSection))?.titlesProjects == false)
        let header = list.rowViews[.section(local)] as? SectionHeaderRowView
        #expect(header?.accessibilityLabel() != "Projects")
    }
}
