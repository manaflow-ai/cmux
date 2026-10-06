import AppKit
import Testing
@testable import CmuxNextSidebar

/// Lawrence 2026-10-05 ("make reordering of our workspace like how the video
/// shows"): in the Arc/Dia sidebar, a row dropped onto the middle of another
/// loose row makes a group of the two. The target row highlights while the
/// card is over its middle, the other rows hold still, and the drop sends one
/// createGroup with both workspaces.
@MainActor @Suite struct SidebarOntoGroupTests {
    @Test func aRowDroppedOnALooseRowsMiddleGroupsTheTwo() throws {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        var sent: [SidebarIntent] = []
        model.onIntent = { [weak model] intent in
            sent.append(intent)
            model?.apply(intent)
        }
        let sidebar = SidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        let cloud = model.sections[2].id

        let x = list.frame(for: try #require(list.displayed.row(for: .workspace(id("x")))))
        let y = list.frame(for: try #require(list.displayed.row(for: .workspace(id("y")))))
        let press = NSPoint(x: y.minX + 40, y: y.midY)
        list.beginDrag(SidebarListView.Press(key: .workspace(id("y")), point: press))
        // Up until the card's leading (top) edge is at x's middle.
        let goal = x.midY + (press.y - y.minY)
        for step in 1...12 {
            let py = press.y + (goal - press.y) * CGFloat(step) / 12
            list.updateDrag(windowPoint: list.convert(NSPoint(x: press.x, y: py), to: nil))
        }
        let drag = try #require(list.drag)
        #expect(drag.target == .ontoWorkspace(id("x")))
        #expect((list.rowViews[.workspace(id("x"))] as? WorkspaceRowView)?.isDropTarget == true, "the target row highlights")
        #expect(list.displayed.row(for: .workspace(id("x"))).map(list.frame(for:)) == x, "the target row holds still")

        list.finishDrag()
        let section = try #require(model.sections.first { $0.id == cloud })
        let groups = section.nodes.compactMap { node -> SidebarGroup? in
            if case let .group(group) = node { return group }
            return nil
        }
        try #require(groups.count == 1, "one new group: \(shape(model.sections, cloud))")
        #expect(Set(groups[0].workspaces.map(\.id)) == [id("x"), id("y")])
        // The group forms at the target row: the intent names it as the anchor.
        let anchors = sent.compactMap { intent -> WorkspaceID? in
            if case let .createGroup(_, _, _, _, anchor) = intent { return anchor }
            return nil
        }
        #expect(anchors == [id("x")])
    }
}
