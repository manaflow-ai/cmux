import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextSidebar

/// Per-section arrangement (list | inline | grid, alignment, gap) and the
/// sticky band height rules (plans/cmux-next/sidebar-sections.md 4, 7).
@Suite struct SectionFlowTests {
    private let m = SidebarRegionMetrics(rowHeight: 28, headerHeight: 22, inset: 8, sectionGap: 8, padding: 4,
                                         cardPadding: 4, tileMinWidth: 42, tileHeight: 36, tileGap: 8, iconButtonWidth: 30)

    private func section(_ arrangement: SectionArrangement, items: [LayoutItem]) -> LayoutSection {
        LayoutSection(id: LayoutSectionID("s"), region: .bottom, look: .builtIn, arrangement: arrangement, items: items)
    }

    private func item(_ id: String, label: Bool = true) -> LayoutItem {
        LayoutItem(id: LayoutItemID(id), ref: .url(id), showsLabel: label)
    }

    @Test func defaultBottomLineIsSettingsLeadingAndTheAvatarTrailing() throws {
        let bottom = try #require(SidebarLayoutDocument.defaults.section(SidebarLayoutDocument.bottomSectionID))
        #expect(bottom.arrangement == SectionArrangement(layout: .inline, align: .fill))
        #expect(bottom.items.map(\.showsLabel) == [true, false])
        let layout = SidebarRegionLayout.make(sections: [bottom], width: 260, look: .quiet, collapsed: [], metrics: m,
                                              labelWidths: [LayoutItemID("itm_settings"): 90])
        #expect(layout.rows.count == 2)
        let settings = layout.rows[0], account = layout.rows[1]
        #expect(settings.kind == .chip(LayoutItemID("itm_settings"), section: bottom.id))
        #expect(account.kind == .tile(LayoutItemID("itm_account"), section: bottom.id))
        #expect(settings.frame.minX == 8 && settings.frame.width == 90)
        #expect(account.frame.maxX == 252 && account.frame.width == 30)
        #expect(settings.frame.minY == account.frame.minY)
    }

    @Test func inlineFallsBackToIconsThenWraps() {
        let items = (0..<6).map { item("i\($0)") }
        let widths = Dictionary(uniqueKeysWithValues: items.map { ($0.id, CGFloat(80)) })
        let fits = SectionFlow.place(section(.inline, items: Array(items.prefix(2))), mode: .inline(iconsOnly: false), x: 0, y: 0,
                                     width: 200, labelWidths: widths, metrics: m)
        #expect(fits.rows.allSatisfy { if case .chip = $0.kind { true } else { false } } && fits.lines == 1)
        let icons = SectionFlow.place(section(.inline, items: items), mode: .inline(iconsOnly: false), x: 0, y: 0,
                                      width: 220, labelWidths: widths, metrics: m)
        #expect(icons.rows.allSatisfy { if case .tile = $0.kind { true } else { false } } && icons.lines == 1)
        let wrapped = SectionFlow.place(section(.inline, items: items), mode: .inline(iconsOnly: false), x: 0, y: 0,
                                        width: 100, labelWidths: widths, metrics: m)
        #expect(wrapped.lines == 3) // two 30-point icons per 100-point line
    }

    @Test func alignmentPlacesLeftoverSpace() {
        let items = [item("a"), item("b")]
        func xs(_ align: SectionArrangement.Alignment) -> [CGFloat] {
            SectionFlow.place(section(SectionArrangement(layout: .inline, align: align, gap: 10), items: items), mode: .inline(iconsOnly: true),
                              x: 0, y: 0, width: 200, labelWidths: [:], metrics: m).rows.map(\.frame.minX)
        }
        #expect(xs(.leading) == [0, 40])
        #expect(xs(.center) == [65, 105])
        #expect(xs(.trailing) == [130, 170])
        #expect(xs(.fill) == [0, 170])
    }

    @Test func gridHonorsColumnsAndFill() {
        let items = (0..<5).map { item("g\($0)") }
        let three = SectionFlow.place(section(SectionArrangement(layout: .grid, align: .fill, gap: 8, columns: 3), items: items),
                                      mode: .grid(columns: 3), x: 0, y: 0, width: 200, labelWidths: [:], metrics: m)
        #expect(three.lines == 2)
        #expect(three.rows[0].frame.width == CGFloat(184) / 3)
        let fixed = SectionFlow.place(section(SectionArrangement(layout: .grid, align: .leading, gap: 8, columns: 2), items: items),
                                      mode: .grid(columns: 2), x: 0, y: 0, width: 200, labelWidths: [:], metrics: m)
        #expect(fixed.rows[0].frame.width == 42 && fixed.lines == 3)
    }

    @Test func arrangementIsValidatedAndRoundTrips() throws {
        let bad = SectionPatch(arrangement: SectionArrangement(layout: .grid, columns: 40))
        let result = SidebarLayoutReducer.reduce(.defaults, .sectionUpdate(SidebarLayoutDocument.topSectionID, bad))
        #expect(result == .failure(.invalidArrangement))
        let good = SectionPatch(arrangement: .grid)
        let doc = try SidebarLayoutReducer.reduce(.defaults, .sectionUpdate(SidebarLayoutDocument.topSectionID, good)).get()
        #expect(doc.section(SidebarLayoutDocument.topSectionID)?.arrangement == .grid)
        let json = #"{"layout":"inline"}"#
        #expect(try JSONDecoder().decode(SectionArrangement.self, from: Data(json.utf8)) == .inline)
        let data = try JSONEncoder().encode(SidebarLayoutDocument.defaults)
        #expect(try JSONDecoder().decode(SidebarLayoutDocument.self, from: data) == .defaults)
    }

    // MARK: Band heights

    private func band(height: CGFloat, capped: CGFloat? = nil) -> SidebarRegionLayout {
        var layout = SidebarRegionLayout.empty
        layout.height = height
        layout.cappedHeight = capped ?? height
        return layout
    }

    @Test func bandsStopAtTheirShareWhenScrolling() {
        let heights = SidebarBandHeights.resolve(above: band(height: 400), below: band(height: 400), available: 600,
                                                 preferences: .defaults, minimumList: 84)
        #expect(heights.above == 200 && heights.below == 150)
        let custom = SidebarBandHeights.resolve(above: band(height: 400), below: band(height: 50), available: 600,
                                                preferences: SidebarSectionsPreferences(topBandMaxShare: 0.5), minimumList: 84)
        #expect(custom.above == 300 && custom.below == 50)
    }

    @Test func neverScrollGivesFullHeightUntilTheListMinimum() {
        let off = SidebarSectionsPreferences(stickyBandsScroll: false)
        let full = SidebarBandHeights.resolve(above: band(height: 250), below: band(height: 100), available: 600, preferences: off, minimumList: 84)
        #expect(full.above == 250 && full.below == 100)
        let squeezed = SidebarBandHeights.resolve(above: band(height: 400), below: band(height: 400), available: 600, preferences: off, minimumList: 84)
        #expect(squeezed.above + squeezed.below <= 516 && squeezed.above == squeezed.below)
        let capped = SidebarBandHeights.resolve(above: band(height: 400, capped: 60), below: band(height: 0), available: 600, preferences: off, minimumList: 84)
        #expect(capped.above == 60)
    }
}
