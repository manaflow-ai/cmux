import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CoreGraphics
import Testing

/// Cloud machines made from one image share that image's workspace ids, and the list keeps one row view per key:
/// a second row with the same id drew nothing, a blank slot above the Cloud rows (Leo 2026-10-29: "why is there all
/// this weird stuff at the bottom of the sidebar", "the rendering gets borked there too :(").
@MainActor struct SidebarOneRowPerWorkspaceTests {
    private func machine(_ name: String, kind: SidebarMachine.Kind, _ nodes: [SidebarNode]) -> SidebarSection {
        SidebarSection(kind: .machine(SidebarMachine(id: MachineID(name), name: name, kind: kind)), nodes: nodes)
    }

    private func workspace(_ id: String) -> SidebarNode {
        .workspace(SidebarWorkspace(id: WorkspaceID(id), title: id))
    }

    private func layout(_ sections: [SidebarSection]) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options)
    }

    /// Four Cloud machines, two of them with the image's workspace: like the sidebar in Leo's capture.
    private var cloned: [SidebarSection] {
        [machine("local", kind: .local, [workspace("ws_mac")]),
         machine("vm-a", kind: .cloud, [workspace("ws_image")]),
         machine("vm-b", kind: .cloud, [workspace("ws_b")]),
         machine("vm-c", kind: .cloud, [workspace("ws_image")]),
         machine("vm-d", kind: .cloud, [workspace("ws_d")])]
    }

    @Test func everyRowHasItsOwnKey() {
        let keys = layout(cloned).rows.map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    @Test func theFirstMachineToListAnIDKeepsIt() throws {
        let row = try #require(layout(cloned).row(for: .workspace(WorkspaceID("ws_image"))))
        #expect(row.section == .machine(MachineID("vm-a")))
    }

    /// Each row starts one row pitch under the one above it: no slot is left for a row that cannot draw.
    @Test func noBlankSlotBetweenRows() {
        let rows = layout(cloned).rows
        let spacing = SidebarLayoutMetrics.standard.rowSpacing
        for (above, below) in zip(rows, rows.dropFirst()) {
            #expect(abs(below.y - (above.maxY + spacing)) < 0.5, "\(below.key) starts \(below.y - above.maxY - spacing) pt late")
        }
    }

    @Test func aRepeatedGroupMemberListsOnce() {
        let group = SidebarGroup(id: GroupID("g"), name: "g", workspaces: [SidebarWorkspace(id: WorkspaceID("ws_image"), title: "x")])
        let sections = [machine("local", kind: .local, [workspace("ws_image")]), machine("vm-a", kind: .cloud, [.group(group)])]
        let keys = layout(sections).rows.map(\.key)
        #expect(keys.filter { $0 == .workspace(WorkspaceID("ws_image")) }.count == 1)
        #expect(keys.contains(.group(GroupID("g"))))
    }

    @Test func sectionsWithoutARepeatAreUntouched() {
        let sections = [machine("local", kind: .local, [workspace("ws_mac")]), machine("vm-b", kind: .cloud, [workspace("ws_b")])]
        #expect(SidebarLayout.listingEachWorkspaceOnce(sections) == sections)
    }

    /// The drawn row shows the first machine's copy, the one whose place it takes: its title and its machine,
    /// never a later machine's.
    @Test func theRowShowsTheFirstMachinesWorkspace() throws {
        let copy = { (title: String) in SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ws_image"), title: title, directory: "~")) }
        let sections = [machine("local", kind: .local, [workspace("ws_mac")]),
                        machine("vm-a", kind: .cloud, [copy("first-copy")]),
                        machine("vm-c", kind: .cloud, [copy("second-copy")])]
        let sidebar = SidebarView(model: SidebarModel(sections: sections), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("ws_image"))] as? WorkspaceRowView)
        #expect(row.title.stringValue == "first-copy")
        #expect(!row.subtitle.stringValue.contains("vm-c"), "the second line names a later machine: \(row.subtitle.stringValue)")
        #expect(sidebar.list.workspaces[WorkspaceID("ws_image")]?.title == "first-copy")
    }
}
