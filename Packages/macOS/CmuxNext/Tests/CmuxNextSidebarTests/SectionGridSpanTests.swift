import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextSidebar

/// R53 (Lawrence 2026-10-03): a grid section places items on rows with
/// fractional widths, each item taking `span` of the section's `columns`
/// (like a CSS grid). First use: R53's bottom row, Settings at 7/8 of the
/// width and the account at 1/8 (a user's grid still lays out this way; the
/// default footer is now icons only, SIDEBAR-FOOTER-MINIMAL).
@Suite struct SectionGridSpanTests {
    private let m = SidebarRegionMetrics(rowHeight: 28, headerHeight: 22, inset: 8, sectionGap: 8, padding: 4,
                                         cardPadding: 4, tileMinWidth: 42, tileHeight: 36, tileGap: 8, iconButtonWidth: 30)

    private func item(_ id: String, span: Int?, label: Bool = true) -> LayoutItem {
        var item = LayoutItem(id: LayoutItemID(id), ref: .url(id), showsLabel: label)
        item.span = span
        return item
    }

    @Test func theR53BottomRowIsSettingsSevenEighthsAndTheAccountOneEighth() throws {
        let bottom = SidebarLayoutDocument.gridBottomSection
        #expect(bottom.arrangement.layout == .grid && bottom.arrangement.columns == 8)
        #expect(bottom.items.map(\.span) == [7, 1])
        let layout = SidebarRegionLayout.make(sections: [bottom], width: 260, look: .quiet, collapsed: [], metrics: m,
                                              labelWidths: [LayoutItemID("itm_settings"): 90])
        #expect(layout.rows.count == 2)
        let settings = layout.rows[0], account = layout.rows[1]
        #expect(settings.kind == .chip(LayoutItemID("itm_settings"), section: bottom.id))
        #expect(account.kind == .tile(LayoutItemID("itm_account"), section: bottom.id))
        // Inner width 260 - 2 * 8 = 244, gap g: unit = (244 - 7g) / 8. Beside a labeled item the
        // icon-only account is a row-height square; Settings gives up the difference.
        let gap = CGFloat(bottom.arrangement.gap ?? 8)
        let unit = (244 - 7 * gap) / 8
        #expect(abs(account.frame.width - m.rowHeight) < 0.01)
        #expect(abs(settings.frame.width - (7 * unit + 6 * gap - (m.rowHeight - unit))) < 0.01)
        #expect(settings.frame.minX == 8 && abs(account.frame.maxX - 252) < 0.01)
        #expect(settings.frame.minY == account.frame.minY && settings.frame.height == m.rowHeight)
    }

    @Test func spansWrapWhenALineIsFull() {
        let section = LayoutSection(id: LayoutSectionID("s"), region: .bottom, look: .builtIn,
                                    arrangement: SectionArrangement(layout: .grid, gap: 0, columns: 4),
                                    items: [item("a", span: 2), item("b", span: 1), item("c", span: 1), item("d", span: 3)])
        let layout = SidebarRegionLayout.make(sections: [section], width: 216, look: .quiet, collapsed: [], metrics: m)
        let frames = layout.rows.map(\.frame)
        // Inner width 200, unit 50.
        #expect(frames.map(\.width) == [100, 50, 50, 150])
        #expect(frames.map(\.minX) == [8, 108, 158, 8])
        #expect(frames[0].minY == frames[2].minY && frames[3].minY > frames[0].minY)
    }

    @Test func aSpanIsValidatedAgainstTheColumnsRange() {
        for span in [0, 13] {
            let added = SidebarLayoutReducer.reduce(.defaults, .itemAdd(item("x", span: span), section: SidebarLayoutDocument.topSectionID, index: 0))
            #expect(added == .failure(.invalidArrangement), "span \(span)")
        }
        let ok = SidebarLayoutReducer.reduce(.defaults, .itemAdd(item("x", span: 12), section: SidebarLayoutDocument.topSectionID, index: 0))
        #expect((try? ok.get()) != nil)
    }

    @Test func aSpanRoundTripsOnTheWire() throws {
        let original = item("a", span: 3)
        let decoded = try JSONDecoder().decode(LayoutItem.self, from: JSONEncoder().encode(original))
        #expect(decoded.span == 3)
    }
}
