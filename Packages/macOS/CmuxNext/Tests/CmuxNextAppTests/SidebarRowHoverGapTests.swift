import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-13: sidebar workspace rows had a ~1 mm gap between them, and
/// moving the pointer down the list dropped the hover highlight in every
/// gap, so it flickered row to row. The rows' hit areas tile: the spacing
/// between two rows belongs to them, so the hover moves from one row to the
/// next in the same pointer step: the new fill shows at once as the old one clears.
/// Since Leo 2026-10-19 the row hovered keeps the gap and the next row takes
/// the hover at its hover pill (`SidebarLayout.hoverRow`); a click acts on the
/// hovered row, or splits the gap when no row is hovered.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowHoverGapTests {
    /// Leo's list: four loose workspaces, in a window. None is active, so
    /// every row's fill is its hover fill.
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

    /// The window point over the list at `y`, inside the rows' width.
    private static func windowPoint(_ list: SidebarListView, y: CGFloat) -> NSPoint {
        list.convert(NSPoint(x: list.bounds.midX, y: y), to: nil)
    }

    @Test func consecutiveRowHitAreasAreContiguous() throws {
        let (list, window, rows) = Self.list()
        defer { window.close() }
        try #require(rows.count == 4)
        let step: CGFloat = 0.25
        for (above, below) in zip(rows, rows.dropFirst()) {
            // The hit area of `above` ends where the one of `below` starts:
            // no y between them hits nothing.
            var lastAbove: CGFloat?
            var firstBelow: CGFloat?
            var y = above.y
            while y < below.maxY {
                let key = list.displayed.row(at: y)?.key
                #expect(key == above.key || key == below.key, "y=\(y) between \(above.key) and \(below.key) hits \(String(describing: key))")
                if key == above.key { lastAbove = y }
                if key == below.key, firstBelow == nil { firstBelow = y }
                y += step
            }
            let end = try #require(lastAbove), start = try #require(firstBelow)
            // row[i].hitMaxY == row[i+1].hitMinY, to the probe's step.
            #expect(start - end == step, "dead hit band of \(start - end - step) pt between \(above.key) and \(below.key)")
        }
    }

    @Test func aPointerSweepDownTheListAlwaysHoversExactlyOneRow() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (list, window, rows) = Self.list()
        defer { window.close() }
        try #require(rows.count == 4)
        let views = try rows.map { try #require(list.rowViews[$0.key]) }
        views.forEach { $0.updateLayer() }
        var previous: SidebarRowKey?
        var switches = 0
        // From the first row's middle to the last's: a row's hover pill (a hit shape, not drawn) starts inside its frame (SidebarRowHoverInsetTests).
        var y = try #require(rows.first).y + rows[0].height / 2
        let end = try #require(rows.last).maxY - rows[0].height / 2
        while y < end {
            list.updateHover(Self.windowPoint(list, y: y))
            views.forEach { $0.updateLayer() }
            let hovered = views.filter(\.isHovered).map(\.key)
            #expect(hovered.count == 1, "y=\(y): \(hovered.count) rows hovered")
            #expect(list.hoveredKey != nil, "y=\(y): hover dropped between rows")
            if let key = list.hoveredKey, let previous, key != previous {
                switches += 1
                // The new fill shows at once (#21543: a sweep never leaves a delayed highlight behind
                // the row under the pointer); the old one clears with the hoverOut token, instant by default.
                let old = try #require(list.rowViews[previous]), new = try #require(list.rowViews[key])
                #expect(new.layer?.animation(forKey: "backgroundColor") == nil, "y=\(y): \(key)'s fill faded in late")
                #expect((old.layer?.animation(forKey: "backgroundColor") != nil) == (Motion.feedback.duration(.hoverOut) > 0),
                        "y=\(y): \(previous)'s fill did not clear with the hoverOut token")
            }
            previous = list.hoveredKey ?? previous
            y += 1
        }
        #expect(switches == rows.count - 1, "the hover visits each row once, top to bottom")
    }
}
