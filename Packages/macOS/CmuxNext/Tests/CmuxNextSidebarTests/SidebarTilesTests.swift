import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextSidebar

/// Sidebar-top tiles (coordinator 2026-10-05): the default top section is a
/// compact grid of large labeled tiles (Safari's favorites) on a tonal card,
/// with a gap before the session list, instead of two plain text rows over
/// a hairline. Stored layouts still equal to the plain-row default move to
/// the tiles through ordinary layout ops.
@MainActor @Suite struct SidebarTilesTests {
    private let m = SidebarRegionMetrics(rowHeight: 28, headerHeight: 22, inset: 8, sectionGap: 8, padding: 4,
                                         cardPadding: 4, tileMinWidth: 42, tileHeight: 36, tileGap: 8)
    private var top: LayoutSection { SidebarLayoutDocument.defaults.section(SidebarLayoutDocument.topSectionID)! }

    // MARK: Layout

    @Test func theDefaultTopSectionLaysOutAsOneLineOfFourLargeTiles() throws {
        #expect(SectionFlow.mode(top, look: .quiet) == .tiles(columns: 4))
        let layout = SidebarRegionLayout.make(sections: [top], width: 240, look: .quiet, collapsed: [], metrics: m)
        #expect(layout.rows.count == 4)
        let frames = layout.rows.map(\.frame)
        #expect(Set(frames.map(\.minY)).count == 1, "one line")
        #expect(frames.allSatisfy { $0.height == m.favoriteHeight })
        #expect(m.favoriteHeight > m.rowHeight * 1.5, "a tile is taller than a row")
        let widths = Set(frames.map { $0.width.rounded() })
        #expect(widths.count == 1, "equal columns")
        #expect(layout.rows.allSatisfy { if case .tile = $0.kind { true } else { false } })
    }

    @Test func tilesSitOnACardAndLeaveAGapBeforeTheList() throws {
        let layout = SidebarRegionLayout.make(sections: [top], width: 240, look: .quiet, collapsed: [], metrics: m)
        let card = try #require(layout.cards.first, "the tonal step")
        for row in layout.rows { #expect(card.insetBy(dx: -0.5, dy: -0.5).contains(row.frame)) }
        #expect(card.minX == m.inset && card.maxX == 240 - m.inset)
        // Below the card: the section gap, then the region's padding.
        #expect(layout.height - card.maxY == m.sectionGap + m.padding)
        #expect(layout.cappedHeight == layout.height, "the tiles never scroll inside")
    }

    @Test func aPlainGridKeepsNoCard() {
        var grid = top
        grid.arrangement = .grid
        let layout = SidebarRegionLayout.make(sections: [grid], width: 240, look: .quiet, collapsed: [], metrics: m)
        #expect(layout.cards.isEmpty)
        #expect(layout.rows.allSatisfy { $0.frame.height == m.tileHeight })
    }

    @Test func moreTilesThanColumnsWrapWithTheSameColumnWidth() {
        var five = top
        five.items.append(LayoutItem(id: LayoutItemID("itm_extra"), ref: .url("https://example.com")))
        let layout = SidebarRegionLayout.make(sections: [five], width: 240, look: .quiet, collapsed: [], metrics: m)
        let lines = Dictionary(grouping: layout.rows, by: { $0.frame.minY })
        #expect(lines.count == 2)
        #expect(layout.rows[4].frame.width == layout.rows[0].frame.width)
        #expect(layout.rows[4].frame.minX == layout.rows[0].frame.minX)
    }

    // MARK: Wire

    @Test func theTilesArrangementRoundTripsAndOlderValuesStillDecode() throws {
        let json = #"{"layout":"tiles","columns":4}"#
        let decoded = try JSONDecoder().decode(SectionArrangement.self, from: Data(json.utf8))
        #expect(decoded == SidebarLayoutDocument.tilesArrangement)
        let data = try JSONEncoder().encode(SidebarLayoutDocument.defaults)
        #expect(try JSONDecoder().decode(SidebarLayoutDocument.self, from: data) == .defaults)
    }

    // MARK: Migration

    private static let homeAndStore = [LayoutItem(id: LayoutItemID("itm_home"), ref: .app("cmux/home")),
                                       LayoutItem(id: LayoutItemID("itm_app_store"), ref: .app("cmux/app-store"))]

    private func stored(top items: [LayoutItem]) -> SidebarLayoutDocument {
        var doc = SidebarLayoutDocument.defaults
        doc.revision = 3
        doc.sections[0] = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: items)
        return doc
    }

    @Test func thePlainRowDefaultBecomesTheTiles() throws {
        let doc = stored(top: Self.homeAndStore)
        #expect(!doc.layoutMigrationOps.isEmpty)
        let migrated = doc.layoutMigration
        #expect(migrated.sections == SidebarLayoutDocument.defaults.sections)
        #expect(migrated.revision > doc.revision)
        #expect(migrated.layoutMigrationOps.isEmpty, "twice is once")
    }

    @Test func thePlainRowDefaultWithCodeRouterKeepsItAfterTheTiles() {
        let coderouter = LayoutItem(id: LayoutItemID("itm_app_coderouter"), ref: .app("cmux/coderouter"))
        let migrated = stored(top: Self.homeAndStore + [coderouter]).layoutMigration
        #expect(migrated.sections == SidebarLayoutDocument.migrationTarget.sections)
    }

    @Test func aChangedTopSectionIsLeftAlone() {
        let customized = [
            stored(top: [Self.homeAndStore[1], Self.homeAndStore[0]]),
            stored(top: [Self.homeAndStore[0]]),
            {
                var doc = stored(top: Self.homeAndStore)
                doc.sections[0].arrangement = .grid
                return doc
            }(),
        ]
        for doc in customized {
            #expect(doc.tilesMigrationOps.isEmpty)
            #expect(doc.layoutMigration == doc)
        }
    }

    // MARK: Tile view

    @Test func aTileDrawsItsGlyphOverACenteredCaption() {
        let view = SidebarItemRowView()
        view.frame = NSRect(x: 0, y: 0, width: 52, height: 64)
        view.configure(SidebarItemInfo(title: "Import and Sync", symbol: "square.and.arrow.down"), style: .favorite)
        view.layoutSubtreeIfNeeded()
        #expect(view.titleFrame.minY >= view.glyphFrame.maxY, "the caption sits under the glyph")
        #expect(abs(view.glyphFrame.midX - 26) < 0.5, "the glyph is centered")
        #expect(abs(view.titleFrame.midX - 26) < 0.5, "the caption is centered")
        #expect(view.toolTip == "Import and Sync", "a truncated caption keeps its full title")
    }

    @Test func anUnreadTileShowsADotNotACount() {
        let view = SidebarItemRowView()
        view.frame = NSRect(x: 0, y: 0, width: 52, height: 64)
        view.configure(SidebarItemInfo(title: "Notifications", symbol: "bell", badge: 3), style: .favorite)
        view.layoutSubtreeIfNeeded()
        #expect(view.isBadgeShown)
        #expect((view.badgeFrame?.width ?? 0) == SidebarStyle.dotSize)
    }
}
