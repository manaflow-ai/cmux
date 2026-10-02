import AppKit
import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextSidebar

/// Review findings on f9373809a84 (sidebar sections): band height sums and
/// small heights, the inline badge, single-item fill, look precedence, grid
/// line alignment.
@MainActor @Suite struct SectionReviewFixTests {
    private let m = SidebarRegionMetrics(rowHeight: 28, headerHeight: 22, inset: 8, sectionGap: 8, padding: 4,
                                         cardPadding: 4, tileMinWidth: 42, tileHeight: 36, tileGap: 8, iconButtonWidth: 30)

    private func band(_ height: CGFloat) -> SidebarRegionLayout {
        var layout = SidebarRegionLayout.empty
        layout.height = height
        layout.cappedHeight = height
        return layout
    }

    private func item(_ id: String, label: Bool = true) -> LayoutItem { LayoutItem(id: LayoutItemID(id), ref: .url(id), showsLabel: label) }

    // MED1: shares that sum past the room leave the list its minimum.
    @Test func scrollModeLeavesTheListItsMinimum() {
        let shares = SidebarSectionsPreferences(topBandMaxShare: 0.6, bottomBandMaxShare: 0.5)
        let h = SidebarBandHeights.resolve(above: band(1_000), below: band(1_000), available: 600, preferences: shares,
                                           minimumList: 84, bandFloor: 28)
        #expect(h.above + h.below <= 600 - 84)
        #expect(h.above > 0 && h.below > 0)
    }

    // LOW11: a tiny sidebar keeps each band's first row (Home, Settings).
    @Test func tinyHeightsKeepEachBandsFirstRow() {
        for scroll in [true, false] {
            let p = SidebarSectionsPreferences(stickyBandsScroll: scroll)
            let h = SidebarBandHeights.resolve(above: band(200), below: band(60), available: 70, preferences: p,
                                               minimumList: 84, bandFloor: 28)
            #expect(h.above >= 28 && h.below >= 28, "scroll \(scroll)")
        }
        let empty = SidebarBandHeights.resolve(above: .empty, below: band(10), available: 70, preferences: .defaults,
                                               minimumList: 84, bandFloor: 28)
        #expect(empty.above == 0 && empty.below == 10)
    }

    // LOW4: one item under fill sits leading.
    @Test func fillWithOneItemIsLeading() {
        let section = LayoutSection(id: LayoutSectionID("s"), region: .bottom, look: .builtIn,
                                    arrangement: SectionArrangement(layout: .inline, align: .fill), items: [item("a")])
        let rows = SectionFlow.place(section, mode: .inline(iconsOnly: true), x: 0, y: 0, width: 200, labelWidths: [:], metrics: m).rows
        #expect(rows.map(\.frame.minX) == [0])
    }

    // LOW5: a short last grid line keeps the columns of the lines above.
    @Test func gridLinesShareColumns() {
        let items = (0..<5).map { item("g\($0)") }
        let section = LayoutSection(id: LayoutSectionID("s"), region: .top, look: .builtIn,
                                    arrangement: SectionArrangement(layout: .grid, align: .center, gap: 8, columns: 3), items: items)
        let rows = SectionFlow.place(section, mode: .grid(columns: 3), x: 0, y: 0, width: 200, labelWidths: [:], metrics: m).rows
        #expect(rows[3].frame.minX == rows[0].frame.minX && rows[4].frame.minX == rows[1].frame.minX)
    }

    // LOW7: an explicit arrangement wins over the tray and lines-icons looks.
    @Test func explicitArrangementWinsOverTheLook() {
        let list = LayoutSection(id: LayoutSectionID("a"), region: .top, look: .builtIn, items: [item("x")])
        #expect(SectionFlow.mode(list, look: .tray) == .grid(columns: nil))
        var inline = list
        inline.arrangement = .inline
        #expect(SectionFlow.mode(inline, look: .tray) == .inline(iconsOnly: false))
        #expect(SectionFlow.mode(inline, look: .linesIcons) == .inline(iconsOnly: false))
    }

    // MED3: an inline chip shows its unread count and says it to VoiceOver.
    @Test func chipShowsTheBadgeAndItsAccessibilityValue() {
        let view = SidebarItemRowView()
        view.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        view.configure(SidebarItemInfo(title: "Notifications", symbol: "bell", badge: 3), style: .chip)
        view.layoutSubtreeIfNeeded()
        #expect(view.isBadgeShown)
        #expect((view.accessibilityValue() as? String) == "3")
        let chipWithBadge = SidebarItemRowView.chipWidth(title: "Notifications", font: SidebarStyle.titleFont, badge: 3)
        #expect(chipWithBadge > SidebarItemRowView.chipWidth(title: "Notifications", font: SidebarStyle.titleFont, badge: nil))
    }
}
