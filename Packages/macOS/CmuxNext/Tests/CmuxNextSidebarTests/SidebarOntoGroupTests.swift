import AppKit
import Testing
@testable import CmuxNextSidebar

/// Lawrence 2026-10-05 ("make reordering of our workspace like how the video
/// shows") and spec 1780d02, Leo 2026-10-06 (a drop on a row did nothing):
/// the card's centre in a loose row's onto band groups the two at once. The
/// row highlights, the other rows hold still, and the drop sends one
/// createGroup with both workspaces, a name and a color, then renames the
/// new group in place. Cmd-Z puts the rows back.
@MainActor @Suite struct SidebarOntoGroupTests {
    final class Harness {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        let sidebar: SidebarView
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var list: SidebarListView { sidebar.list }

        init() {
            sidebar = SidebarView(model: model)
            window.isReleasedWhenClosed = false
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
            window.contentView?.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
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

    @Test func aSquareDropOnALooseRowGroupsTheTwo() throws {
        let h = Harness()
        defer { h.window.close() }
        let x = try h.frame(.workspace(id("x")))
        try h.drag(.workspace(id("y")), over: .workspace(id("x")), at: 0.5)
        let drag = try #require(h.list.drag)
        #expect(drag.target == .ontoWorkspace(id("x")), "no dwell")
        #expect((h.list.rowViews[.workspace(id("x"))] as? WorkspaceRowView)?.isDropTarget == true, "the target row highlights")
        #expect(try h.frame(.workspace(id("x"))) == x, "the target row holds still")

        h.list.finishDrag()
        let groups = h.groups(cloudSection)
        try #require(groups.count == 1, "one new group: \(shape(h.model.sections, cloudSection))")
        #expect(groups[0].workspaces.map(\.id) == [id("x"), id("y")])
        #expect(groups[0].name == SidebarGroup.named(""))
        #expect(groups[0].color != .grey)
        #expect(h.list.inlineRename.session?.key == .group(groups[0].id), "the new group renames in place")
        let field = try #require(h.list.inlineRename.session?.field)
        let header = try h.frame(.group(groups[0].id)), title = try #require(h.list.rowViews[.group(groups[0].id)]).titleFrame
        #expect(abs(field.frame.midY - (header.minY + title.midY)) < 1, "the rename field sits on the header's settled title")

        h.list.inlineRename.end(commit: false)
        h.window.undoManager?.undo()
        #expect(h.groups(cloudSection).isEmpty)
        #expect(shape(h.model.sections, cloudSection) == "x y")
    }

    /// The home daemon makes the group under its own id: the rename follows
    /// the group its row moved to and keeps what was typed.
    @Test func theRenameFollowsTheGroupTheStoreMadeInItsPlace() throws {
        let h = Harness()
        defer { h.window.close() }
        try h.drag(.workspace(id("y")), over: .workspace(id("x")), at: 0.5)
        h.list.finishDrag()
        let made = try #require(h.groups(cloudSection).first)
        try #require(h.list.inlineRename.session?.key == .group(made.id))
        h.list.inlineRename.session?.field.stringValue = "Infra"

        let stored = GroupID.make()
        h.model.send(.ungroup(made.id))
        h.model.send(.createGroup(stored, name: made.name, color: made.color, workspaces: [id("x"), id("y")], anchor: id("x")))
        h.list.reload(animated: false)
        #expect(h.list.inlineRename.session?.key == .group(stored))
        #expect(h.list.inlineRename.session?.field.stringValue == "Infra")
        #expect(h.list.subviews.filter { $0 is NSTextField }.count == 1, "no orphaned field")
    }

    @Test func theBandsEdgesAreStickyOnceEntered() throws {
        let h = Harness()
        defer { h.window.close() }
        try h.drag(.workspace(id("y")), over: .workspace(id("x")), at: 0.5)
        let x = try h.frame(.workspace(id("x")))
        h.move(to: x.minY + x.height * 0.73)
        #expect(h.list.drag?.target == .ontoWorkspace(id("x")), "past the band's edge, still grouping")
        h.list.cancelDrag()
        #expect(h.groups(cloudSection).isEmpty, "Esc groups nothing")
        #expect(shape(h.model.sections, cloudSection) == "x y")
    }

    /// In one list (`sidebar.groupByComputer` off) too: the top of the
    /// first row of another computer is a slot of that computer, not the end
    /// of the rows above it (cx-hzpd).
    @Test func theTopOfARowReorders() throws {
        let h = Harness()
        defer { h.window.close() }
        try #require(h.model.groupsByComputer == false)
        try h.drag(.workspace(id("y")), over: .workspace(id("x")), at: 0.1)
        #expect(h.list.drag?.target == .position(DropPosition(section: cloudSection, index: 0)))
        h.list.finishDrag()
        #expect(h.groups(cloudSection).isEmpty)
        #expect(shape(h.model.sections, cloudSection) == "y x")
    }

    @Test func undoTakesAJoinedRowBackOut() throws {
        let h = Harness()
        defer { h.window.close() }
        let origin = SidebarEdits.position(of: id("c"), in: h.model.sections)
        SidebarGroupDrop.join(h.list, [id("c")], g1, origin: origin)
        #expect(shape(h.model.sections, local).contains("G1[g1,g2,g3,c]"))
        h.window.undoManager?.undo()
        #expect(shape(h.model.sections, local).contains("G1[g1,g2,g3]"))
        #expect(!shape(h.model.sections, local).contains("g3,c]"))
    }
}
