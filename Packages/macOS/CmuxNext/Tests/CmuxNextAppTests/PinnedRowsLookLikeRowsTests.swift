import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-26 ("pinned workspaces need to look like normal workspaces, not compact square"):
/// a pinned workspace drew as a small square tile because `sec_pinned` laid out as a grid. It draws as a
/// full-width row like any workspace, with the pin leading it (user 13159: "should have pin logo on left").
@MainActor @Suite(.serialized)
struct PinnedRowsLookLikeRowsTests {
    static let first = LayoutItem(id: LayoutItemID("itm_pin_a"), ref: .workspace("local:ws_a"))
    static let second = LayoutItem(id: LayoutItemID("itm_pin_b"), ref: .workspace("local:ws_b"))
    static let width: CGFloat = 240

    /// The region layout the sidebar draws for `section` alone, at the standard metrics.
    static func region(_ section: LayoutSection) -> SidebarRegionLayout {
        SidebarRegionLayout.make(sections: [section], width: width, look: .quiet, collapsed: [],
                                 metrics: .standard)
    }

    @Test func aNewPinnedSectionLaysOutAsRows() {
        let section = SidebarLayoutDocument.pinnedSection(items: [Self.first, Self.second])
        #expect(section.arrangement.layout == .list)
    }

    @Test func aPinnedSectionStoredAsAGridStillDrawsRows() {
        // Stored layouts from before the change carry `arrangement: grid`; the pinned section ignores it.
        var section = SidebarLayoutDocument.pinnedSection(items: [Self.first, Self.second])
        section.arrangement = .grid
        let rows = Self.region(section).rows.filter { if case .header = $0.kind { false } else { true } }
        #expect(rows.count == 2)
        for row in rows {
            guard case .item = row.kind else {
                Issue.record("a pinned workspace drew as \(row.kind), not a row")
                continue
            }
            #expect(row.frame.width == Self.width - SidebarRegionMetrics.standard.trailingTrim, "a row spans the sidebar width, not a square tile")
            #expect(row.frame.height == SidebarRegionMetrics.standard.rowHeight)
        }
        #expect(rows.count == 2 && abs(rows[1].frame.minY - rows[0].frame.maxY) < 0.01, "rows stack one under the other")
    }

    @Test func aPinnedRowDrawsThePinLeadingItsTitle() {
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 32))
        var info = SidebarItemInfo(title: "workspace-1", symbol: "textformat")
        info.textOnly = true
        info.leadingPin = true
        row.configure(info, style: .builtIn)
        row.layoutSubtreeIfNeeded()
        row.layout()
        let pin = try? #require(row.pinInkFrame)
        #expect(pin != nil, "a pinned workspace row shows its pin")
        if let pin {
            #expect(pin.minX < row.title.frame.minX, "the pin sits on the left of the title")
        }
    }
}
