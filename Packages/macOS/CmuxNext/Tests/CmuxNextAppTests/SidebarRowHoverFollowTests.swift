import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-20: moving the pointer between sidebar workspace rows, the old row's hover stayed
/// lit while the pointer was already on the next row's fill (its right end, where the x sits, and
/// its top and bottom edges), so the pointer felt trapped. The hover follows the pointer: on
/// another row's fill that row takes it at once, one row at a time. Rows also stop short of the
/// sidebar's right edge (Chrome's vertical tabs), so a row's pill never runs to the edge.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowHoverFollowTests {
    private static func list() -> (SidebarListView, NSWindow, [SidebarRow]) {
        let titles = ["newtab", "workspace-2", "workspace-3", "Agent Activity"]
        let workspaces = titles.enumerated().map { SidebarWorkspace(id: WorkspaceID("ws-\($0.offset)"), title: $0.element) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                 activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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

    /// From the row below up onto the right end of the row above (its x's corner): the row above.
    @Test func theRowUnderThePointerTakesTheHoverAtOnce() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
        try #require(rows.count == 4)
        let above = rows[1], below = rows[2]
        let frameAbove = list.frame(for: above), frameBelow = list.frame(for: below)
        #expect(Self.hover(list, x: frameBelow.midX, y: frameBelow.midY) == below.key)
        for (x, y) in [(frameAbove.maxX - 1, frameAbove.maxY - 1), (frameAbove.midX, frameAbove.maxY - 1),
                       (frameAbove.maxX - 1, frameAbove.midY)] as [(CGFloat, CGFloat)] {
            list.setHovered(below.key)
            #expect(Self.hover(list, x: x, y: y) == above.key, "(\(x), \(y)) on the row above kept \(String(describing: list.hoveredKey))")
            let lit = rows.compactMap { list.rowViews[$0.key] }.filter(\.isHovered).map(\.key)
            #expect(lit == [above.key], "rows lit: \(lit)")
        }
    }

    /// Leo 2026-10-27: the row's fill ends 1.5 pt from the sidebar's right edge (#26378).
    @Test func aRowEndsShortOfTheSidebarsRightEdge() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
        let frame = list.frame(for: try #require(rows.first))
        let right = list.bounds.maxX - frame.maxX
        #expect(abs(right - 1.5) < 0.01, "the row ends \(right) pt from the right edge; expected 1.5 pt")
    }
}
