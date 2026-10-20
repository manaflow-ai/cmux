import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-19: moving the pointer up and to the left out of a sidebar
/// row, it crossed the gap and the rounded corner of the row above, which
/// took the hover and showed its "..." and close buttons in his way. A row
/// takes the hover only inside its rounded pill, never in the gap, a
/// corner, or the margin beside it. The row already hovered keeps it across
/// the gap, so a sweep down or up the list never flickers (#20315).
@MainActor @Suite(.serialized) struct SidebarRowHoverInsetTests {
    private static func list() -> (SidebarListView, NSWindow, [SidebarRow]) {
        let titles = ["newtab", "workspace-2", "workspace-3", "Agent Activity"]
        let workspaces = titles.enumerated().map { SidebarWorkspace(id: WorkspaceID("ws-\($0.offset)"), title: $0.element) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                 activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = list
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        list.reload(animated: false)
        let rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        return (list, window, rows)
    }

    private static func hover(_ list: SidebarListView, x: CGFloat, y: CGFloat) -> SidebarRowKey? {
        list.updateHover(list.convert(NSPoint(x: x, y: y), to: nil))
        return list.hoveredKey
    }

    @Test func theGapBetweenTwoRowsHoversNeitherWhenNothingIsHovered() throws {
        let (list, window, rows) = Self.list()
        defer { window.orderOut(nil) }
        try #require(rows.count == 4)
        let above = rows[1], below = rows[2]
        try #require(below.y > above.maxY, "the rows have no gap")
        let x = list.frame(for: above).midX
        var y = above.maxY
        while y < below.y {
            list.setHovered(nil)
            #expect(Self.hover(list, x: x, y: y) == nil, "y=\(y) in the gap hovers \(String(describing: list.hoveredKey))")
            y += 0.25
        }
    }

    @Test func aRowsRoundedCornerDoesNotTakeTheHoverFromTheRowBelow() throws {
        let (list, window, rows) = Self.list()
        defer { window.orderOut(nil) }
        try #require(rows.count == 4)
        let above = rows[1], below = rows[2]
        let frameAbove = list.frame(for: above), frameBelow = list.frame(for: below)
        #expect(Self.hover(list, x: frameBelow.midX, y: frameBelow.midY) == below.key)
        // Up and to the left: into the bottom-left corner of the row above.
        for (dx, dy) in [(0.5, 0.5), (1.0, 1.0), (1.5, 0.5), (0.5, 1.5)] as [(CGFloat, CGFloat)] {
            let key = Self.hover(list, x: frameAbove.minX + dx, y: frameAbove.maxY - dy)
            #expect(key != above.key, "the corner at (+\(dx), -\(dy)) took the hover")
        }
        // And the top-left corner, coming from above the row.
        list.setHovered(nil)
        #expect(Self.hover(list, x: frameAbove.minX + 0.5, y: frameAbove.minY + 0.5) == nil)
    }

    @Test func theMarginBesideARowDoesNotHoverIt() throws {
        let (list, window, rows) = Self.list()
        defer { window.orderOut(nil) }
        let row = try #require(rows.first)
        let frame = list.frame(for: row)
        try #require(frame.minX >= 1, "the rows fill the list's width")
        list.setHovered(nil)
        #expect(Self.hover(list, x: frame.minX / 2, y: frame.midY) == nil)
        #expect(Self.hover(list, x: frame.midX, y: frame.midY) == row.key)
    }

    @Test func aSweepUpTheListKeepsExactlyOneRowHovered() throws {
        let (list, window, rows) = Self.list()
        defer { window.orderOut(nil) }
        try #require(rows.count == 4)
        let x = list.frame(for: rows[0]).midX
        var y = try #require(rows.last).maxY - list.frame(for: rows[0]).height / 2
        var visited: [SidebarRowKey] = []
        while y > rows[0].y + rows[0].height / 2 {
            let key = Self.hover(list, x: x, y: y)
            #expect(key != nil, "y=\(y): hover dropped between rows")
            if let key, visited.last != key { visited.append(key) }
            y -= 0.5
        }
        #expect(visited == rows.reversed().map(\.key), "the hover visits each row once, bottom to top")
    }
}
