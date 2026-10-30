import AppKit
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20 (nightly): "the group headers render as flat gray pills during drag". A held drag shows rows from
/// the model's live sections, but configured them from the list's group cache, which only a reload rebuilds; the
/// sidebar reloads a turn after the model changes. A group the model gained in that gap (an agent or the CLI made it,
/// or a new group's id was replaced by the daemon's) showed a header that was never configured: no name, no
/// chevron, the default gray bar, and nothing configures it again while the drag is held.
@MainActor @Suite(.serialized) struct SidebarDragHeaderTests {
    @Test func aGroupTheModelGainsMidDragShowsItsHeader() throws {
        let (list, window) = SidebarPointerGestureTests.list()
        defer { window.close() }
        let start = try SidebarPointerGestureTests.point(list, .workspace(WorkspaceID("x")))
        try SidebarPointerGestureTests.press(list, at: start, moves: [CGVector(dx: 0, dy: 12)], release: false)
        #expect(list.drag != nil, "the fixture's drag did not start")

        // The model changes under the held drag; the list has not reloaded yet.
        var sections = list.model.sections
        let index = try #require(sections[0].nodes.firstIndex { if case let .workspace(ws) = $0 { ws.id == WorkspaceID("y") } else { false } })
        let three = SidebarGroup(id: GroupID("g3"), name: "Three", color: .orange,
                                 workspaces: [SidebarWorkspace(id: WorkspaceID("y"), title: "y")])
        sections[0].nodes[index] = .group(three)
        list.model.sections = sections
        list.mouseDragged(with: try SidebarPointerGestureTests.event(list, .leftMouseDragged, at: NSPoint(x: start.x, y: start.y + 14)))

        let header = try #require(list.rowViews[.group(GroupID("g3"))] as? GroupHeaderRowView, "the drag layout shows no header for g3")
        #expect(header.accessibilityLabel()?.hasPrefix("Three") == true, "the header was never configured: a nameless gray bar")
        list.mouseUp(with: try SidebarPointerGestureTests.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y + 14)))
    }
}
