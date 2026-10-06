import AppKit
import Testing
@testable import CmuxNextSidebar

/// Lawrence 2026-10-05 ("make reordering of our workspace like how the video
/// shows"), Leo 2026-10-06 (drop on a row did nothing, and reorder against
/// drop-on was far too sensitive): the pointer resting in the middle half of
/// a loose row groups the two. The row highlights after the dwell, the
/// other rows hold still, and the drop sends one createGroup with both
/// workspaces, a name and a color, then renames the new group in place.
/// Cmd-Z puts the rows back.
@MainActor @Suite struct SidebarOntoGroupTests {
    final class Harness {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        let sidebar: SidebarView
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var now: TimeInterval = 100
        var list: SidebarListView { sidebar.list }

        init() {
            sidebar = SidebarView(model: model)
            window.isReleasedWhenClosed = false
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
            window.contentView?.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            sidebar.list.dragClock = { [unowned self] in self.now }
        }

        func frame(_ key: SidebarRowKey) throws -> NSRect { list.frame(for: try #require(list.displayed.row(for: key))) }

        /// Drags `key` from its middle until the pointer is at `fraction` of `over`, in steps.
        func drag(_ key: SidebarRowKey, over: SidebarRowKey, at fraction: CGFloat) throws {
            let from = try frame(key), to = try frame(over)
            let press = NSPoint(x: from.minX + 40, y: from.midY)
            list.beginDrag(SidebarListView.Press(key: key, point: press))
            let goal = to.minY + to.height * fraction
            for step in 1...12 {
                move(to: press.y + (goal - press.y) * CGFloat(step) / 12)
            }
        }

        func move(to y: CGFloat) {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: 80, y: y), to: nil))
        }

        func groups(_ section: SectionID) -> [SidebarGroup] {
            model.sections.first { $0.id == section }?.nodes.compactMap { node -> SidebarGroup? in
                if case let .group(group) = node { return group }
                return nil
            } ?? []
        }
    }

    @Test func aRowRestingOnALooseRowsMiddleGroupsTheTwo() throws {
        let h = Harness()
        defer { h.window.close() }
        let x = try h.frame(.workspace(id("x")))
        try h.drag(.workspace(id("y")), over: .workspace(id("x")), at: 0.5)
        #expect(h.list.drag?.target != .ontoWorkspace(id("x")), "no group before the dwell")
        #expect(try h.frame(.workspace(id("x"))) == x, "the row under the pointer holds still while it waits")

        h.now += SidebarGroupDwell.dwell
        SidebarGroupDrop.dwellElapsed(h.list)
        let drag = try #require(h.list.drag)
        #expect(drag.target == .ontoWorkspace(id("x")))
        #expect((h.list.rowViews[.workspace(id("x"))] as? WorkspaceRowView)?.isDropTarget == true, "the target row highlights")
        #expect(try h.frame(.workspace(id("x"))) == x, "the target row holds still")

        h.list.finishDrag()
        let groups = h.groups(cloudSection)
        try #require(groups.count == 1, "one new group: \(shape(h.model.sections, cloudSection))")
        #expect(groups[0].workspaces.map(\.id) == [id("x"), id("y")])
        #expect(groups[0].name == Strings.newGroupName)
        #expect(groups[0].color != .grey)
        #expect(h.list.inlineRename.session?.key == .group(groups[0].id), "the new group renames in place")

        h.list.inlineRename.end(commit: false)
        h.window.undoManager?.undo()
        #expect(h.groups(cloudSection).isEmpty)
        #expect(shape(h.model.sections, cloudSection) == "x y")
    }

    @Test func aQuickPassOverTheMiddleReordersInstead() throws {
        let h = Harness()
        defer { h.window.close() }
        // Through x's middle without stopping, into its top quarter.
        try h.drag(.workspace(id("y")), over: .workspace(id("x")), at: 0.1)
        h.now += SidebarGroupDwell.dwell
        SidebarGroupDrop.dwellElapsed(h.list)
        #expect(h.list.drag?.target == .position(DropPosition(section: cloudSection, index: 0)))
        h.list.finishDrag()
        #expect(h.groups(cloudSection).isEmpty)
        #expect(shape(h.model.sections, cloudSection) == "y x")
    }

    @Test func aRowRestingOnAGroupHeaderJoinsItAndEscapeCancels() throws {
        let h = Harness()
        defer { h.window.close() }
        try h.drag(.workspace(id("c")), over: .group(g1), at: 0.5)
        h.now += SidebarGroupDwell.dwell
        SidebarGroupDrop.dwellElapsed(h.list)
        #expect(h.list.drag?.target == .intoGroup(g1))
        h.list.cancelDrag()
        #expect(shape(h.model.sections, local).contains("G1[g1,g2,g3]"))

        try h.drag(.workspace(id("c")), over: .group(g1), at: 0.5)
        h.now += SidebarGroupDwell.dwell
        SidebarGroupDrop.dwellElapsed(h.list)
        h.list.finishDrag()
        #expect(shape(h.model.sections, local).contains("G1[g1,g2,g3,c]"))
        h.window.undoManager?.undo()
        #expect(shape(h.model.sections, local).hasSuffix("c"))
        #expect(shape(h.model.sections, local).contains("G1[g1,g2,g3]"))
    }
}
