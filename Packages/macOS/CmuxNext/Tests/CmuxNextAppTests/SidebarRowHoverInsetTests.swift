import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-19: moving the pointer up and to the left out of a sidebar
/// row, it crossed the gap and the rounded corner of the row above, which
/// took the hover and showed its "..." and close buttons in his way. A row
/// takes the hover from rest only inside its rounded pill, never in the gap, a
/// corner, or the margin beside it. The row already hovered keeps it across
/// the gap, so a sweep down or up the list never flickers (#20315). Since Leo
/// 2026-10-20 a hovered row hands the hover to any row whose fill the pointer
/// is on (`SidebarRowHoverFollowTests`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowHoverInsetTests {
    private static func list(grouped: Bool = false) -> (SidebarListView, NSWindow, [SidebarRow]) {
        let titles = ["newtab", "workspace-2", "workspace-3", "Agent Activity"]
        let workspaces = titles.enumerated().map { SidebarWorkspace(id: WorkspaceID("ws-\($0.offset)"), title: $0.element) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes: [CmuxNextSidebar.SidebarNode] = grouped
            ? [.group(SidebarGroup(id: GroupID("g1"), name: "Group", color: .green, workspaces: workspaces))]
            : workspaces.map { .workspace($0) }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: nil)
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

    @Test func theGapBetweenTwoRowsHoversNeitherWhenNothingIsHovered() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
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

    @Test func aRowsRoundedCornerTakesNoHoverFromRest() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
        try #require(rows.count == 4)
        let above = rows[1]
        let frameAbove = list.frame(for: above)
        // The bottom-left corner of a row, with no row hovered.
        for (dx, dy) in [(0.5, 0.5), (1.0, 1.0), (1.5, 0.5), (0.5, 1.5)] as [(CGFloat, CGFloat)] {
            list.setHovered(nil)
            let key = Self.hover(list, x: frameAbove.minX + dx, y: frameAbove.maxY - dy)
            #expect(key != above.key, "the corner at (+\(dx), -\(dy)) took the hover")
        }
        // And the top-left corner, coming from above the row.
        list.setHovered(nil)
        #expect(Self.hover(list, x: frameAbove.minX + 0.5, y: frameAbove.minY + 0.5) == nil)
    }

    @Test func theMarginBesideARowDoesNotHoverIt() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
        let row = try #require(rows.first)
        let frame = list.frame(for: row)
        try #require(frame.minX >= 1, "the rows fill the list's width")
        list.setHovered(nil)
        #expect(Self.hover(list, x: frame.minX / 2, y: frame.midY) == nil)
        #expect(Self.hover(list, x: frame.midX, y: frame.midY) == row.key)
    }

    @Test func aSweepUpTheListKeepsExactlyOneRowHovered() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
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

    /// Review of #22294: a click acts on the row that shows the hover. The
    /// hovered row keeps the hover in the gap, on the row above's side of it,
    /// so a click there must not act on the row above.
    @Test func aClickActsOnTheHoveredRowNotTheTileUnderThePointer() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
        try #require(rows.count == 4)
        let above = rows[1], below = rows[2]
        let frameAbove = list.frame(for: above), frameBelow = list.frame(for: below)
        #expect(Self.hover(list, x: frameBelow.midX, y: frameBelow.midY) == below.key)
        try #require(frameBelow.minY - frameAbove.maxY > 0.5, "the rows have no gap")
        let point = NSPoint(x: frameAbove.midX, y: frameAbove.maxY + 0.25)
        #expect(Self.hover(list, x: point.x, y: point.y) == below.key, "the row below lost the hover")
        let location = list.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }
        list.mouseDown(with: try event(.leftMouseDown))
        list.mouseUp(with: try event(.leftMouseUp))
        guard case let .workspace(id) = below.key else { Issue.record("not a workspace row"); return }
        #expect(list.model.selection == [id], "the click selected \(list.model.selection), not the hovered row")
    }

    @Test func thePillRoundsItsCornersInsideTheInset() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 30)
        func pill(_ x: CGFloat, _ y: CGFloat, r: CGFloat = 10) -> Bool {
            SidebarLayout.pill(rect, inset: 4, cornerRadius: r, contains: CGPoint(x: x, y: y))
        }
        #expect(pill(50, 15))
        #expect(!pill(50, 3.5), "the inset above the pill")
        #expect(!pill(50, 26.5), "the inset below the pill")
        #expect(pill(50, 4) && pill(0.5, 15), "the pill's top edge and left side")
        #expect(pill(4, 8), "inside the top-left corner's arc")
        #expect(!pill(2, 6), "outside the top-left corner's arc")
        #expect(!pill(2, 24), "outside the bottom-left corner's arc")
        #expect(!pill(98, 6) && !pill(98, 24), "outside the right corners' arcs")
        #expect(!pill(100, 15) && !pill(-0.5, 15), "beside the pill")
    }

    @Test func aRadiusPastHalfThePillsHeightClampsToACapsule() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 10)
        for r: CGFloat in [3, 1000] {
            #expect(SidebarLayout.pill(rect, inset: 2, cornerRadius: r, contains: CGPoint(x: 0.5, y: 5)), "r=\(r)")
            #expect(!SidebarLayout.pill(rect, inset: 2, cornerRadius: r, contains: CGPoint(x: 0.5, y: 2.5)), "r=\(r)")
        }
        #expect(!SidebarLayout.pill(rect, inset: 5, cornerRadius: 3, contains: CGPoint(x: 50, y: 5)), "an inset that eats the row")
    }

    @Test func theBottomLeftCornerOfTheRowAboveHoversNothingFromRest() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
        let frameAbove = list.frame(for: rows[1])
        list.setHovered(nil)
        #expect(Self.hover(list, x: frameAbove.minX + 1, y: frameAbove.maxY - Metrics.space1 - 1) == nil)
    }

    @Test func theFirstRowsTopEdgeHoversNothing() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
        let frame = list.frame(for: try #require(rows.first))
        list.setHovered(nil)
        #expect(Self.hover(list, x: frame.midX, y: frame.minY + Metrics.space1 / 2) == nil)
    }

    @Test func aGroupedRowsPillStartsAtItsGutter() throws {
        let (list, window, rows) = Self.list(grouped: true)
        defer { window.close() }
        let row = try #require(rows.first(where: { $0.group != nil }), "no grouped row")
        let frame = list.frame(for: row)
        try #require(frame.minX >= 1)
        list.setHovered(nil)
        #expect(Self.hover(list, x: frame.minX - 0.5, y: frame.midY) == nil, "the gutter took the hover")
        #expect(Self.hover(list, x: frame.midX, y: frame.midY) == row.key)
    }
}
