import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A frame read inside a pass (`SidebarListView.withRowGeometry`) is the frame read outside one, for every row kind
/// (group headers that reach over their rails, members, loose rows), and a width change inside a pass reads the
/// geometry again (``SidebarRowGeometryTests``).
@MainActor @Suite struct SidebarRowGeometryPassTests {
    @Test func aFrameInAPassIsTheFrameOutsideOne() throws {
        let h = SidebarRowGeometryTests.make(60)
        defer { h.window.close() }
        let list = h.list
        let rows = list.displayed.rows
        try #require(rows.contains { if case .group = $0.key { true } else { false } }, "no group header listed")
        let outside = rows.map { list.frame(for: $0) }
        let inside = list.withRowGeometry { rows.map { list.frame(for: $0) } }
        #expect(inside == outside)
        let reaches = rows.map { list.railReach(for: $0) }
        #expect(list.withRowGeometry { rows.map { list.railReach(for: $0) } } == reaches)
        #expect(reaches.contains { $0 > 0 }, "no group header reaches over its rail")
    }

    @Test func aWidthChangeInsideAPassReadsTheNewWidth() throws {
        let h = SidebarRowGeometryTests.make(60)
        defer { h.window.close() }
        let list = h.list
        let row = try #require(list.displayed.rows.first { if case .workspace = $0.key { true } else { false } })
        let (narrow, wide) = list.withRowGeometry { () -> (NSRect, NSRect) in
            let narrow = list.frame(for: row)
            list.setFrameSize(NSSize(width: list.bounds.width + 80, height: list.bounds.height))
            return (narrow, list.frame(for: row))
        }
        #expect(wide.width == narrow.width + 80, "a frame read after the width changed kept the old width")
        #expect(list.passRowGeometry == nil, "the pass left its geometry behind")
    }
}
