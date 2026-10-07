import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextSidebar

/// Pinned workspace tiles and top rows (PINNED-ITEMS-END-TO-END): the first
/// pin adds `sec_pinned` under `sec_top`, it draws only with items, unpin
/// and undo are exact inverses, and the legacy pin migration is lossless
/// and idempotent.
@Suite struct SidebarPinnedSectionTests {
    private let defaults = SidebarLayoutDocument.defaults
    private let alpha = LayoutItemRef.workspace("sess:ws_alpha")
    private let beta = LayoutItemRef.workspace("sess:ws_beta")

    private func apply(_ doc: SidebarLayoutDocument, _ op: SidebarLayoutOp?) throws -> SidebarLayoutDocument {
        try SidebarLayoutReducer.reduce(doc, try #require(op)).get()
    }

    @Test func theFirstPinAddsTheGridSectionUnderTheTopRows() throws {
        #expect(defaults.section(SidebarLayoutDocument.pinnedSectionID) == nil)
        let doc = try apply(defaults, defaults.pinOp(alpha))
        let top = doc.sections(in: .top, room: nil)
        #expect(top.map(\.id) == [SidebarLayoutDocument.topSectionID, SidebarLayoutDocument.pinnedSectionID])
        let pinned = try #require(doc.section(SidebarLayoutDocument.pinnedSectionID))
        #expect(pinned.arrangement.layout == .grid)
        #expect(pinned.look == .builtIn)
        #expect(pinned.headerTitle == nil)
        #expect(pinned.items.map(\.ref) == [alpha])
        #expect(doc.isPinned(alpha))
    }

    @Test func laterPinsAppendAndAPinnedRefIsNotPinnedTwice() throws {
        var doc = try apply(defaults, defaults.pinOp(alpha))
        doc = try apply(doc, doc.pinOp(beta))
        #expect(doc.section(SidebarLayoutDocument.pinnedSectionID)?.items.map(\.ref) == [alpha, beta])
        #expect(doc.pinOp(alpha) == nil)
    }

    @Test func withoutTheTopRowsTheSectionGoesLastInTheTopRegion() throws {
        let noTop = try apply(defaults, .sectionRemove(SidebarLayoutDocument.topSectionID))
        let doc = try apply(noTop, noTop.pinOp(alpha))
        #expect(doc.sections(in: .top, room: nil).map(\.id) == [SidebarLayoutDocument.pinnedSectionID])
    }

    @Test func anEmptyPinnedSectionDrawsNothing() throws {
        let pinned = try apply(defaults, defaults.pinOp(alpha))
        let empty = try apply(pinned, pinned.unpinOp(alpha))
        #expect(empty.section(SidebarLayoutDocument.pinnedSectionID)?.items.isEmpty == true)
        let metrics = SidebarRegionMetrics(rowHeight: 28, headerHeight: 22, inset: 8, sectionGap: 6, padding: 4, cardPadding: 6,
                                           tileMinWidth: 40, tileHeight: 40, tileGap: 4)
        let layout = SidebarRegionLayout.make(sections: [try #require(empty.section(SidebarLayoutDocument.pinnedSectionID))], width: 240,
                                              look: .quiet, collapsed: [], metrics: metrics)
        #expect(layout == .empty)
    }

    @Test func unpinRemovesOnlyTheTileAndUndoPutsItBackInPlace() throws {
        var doc = try apply(defaults, defaults.pinOp(alpha))
        doc = try apply(doc, doc.pinOp(beta))
        doc = try apply(doc, doc.addToTopOp(alpha))
        let unpin = try #require(doc.unpinOp(alpha))
        let undo = try #require(doc.inverse(of: unpin))
        let unpinned = try apply(doc, unpin)
        #expect(!unpinned.isPinned(alpha))
        #expect(unpinned.isOnTop(alpha), "the top row of the same workspace stays")
        let restored = try apply(unpinned, undo)
        #expect(restored.sections == doc.sections, "undo restores the tile with its id at its index")
        let redo = try #require(unpinned.inverse(of: undo), "the inverse of the undo, planned on the layout it applies to")
        #expect(try apply(restored, redo).sections == unpinned.sections)
    }

    @Test func undoOfTheFirstPinRemovesTheTile() throws {
        let op = try #require(defaults.pinOp(alpha))
        let undo = try #require(defaults.inverse(of: op))
        let pinned = try apply(defaults, op)
        #expect(try !apply(pinned, undo).isPinned(alpha))
    }

    @Test func addToTopAppendsToTheTopRowsAndRemoveFromTopKeepsTiles() throws {
        var doc = try apply(defaults, defaults.pinOp(alpha))
        doc = try apply(doc, doc.addToTopOp(alpha))
        #expect(doc.section(SidebarLayoutDocument.topSectionID)?.items.map(\.ref).last == alpha)
        #expect(doc.addToTopOp(alpha) == nil)
        let app = LayoutItemRef.app("acme/notes")
        doc = try apply(doc, doc.addToTopOp(app))
        #expect(doc.section(SidebarLayoutDocument.topSectionID)?.items.map(\.ref).suffix(2) == [alpha, app])
        doc = try apply(doc, doc.removeFromTopOp(alpha))
        #expect(doc.isPinned(alpha))
        #expect(doc.section(SidebarLayoutDocument.topSectionID)?.items.contains { $0.ref == alpha } == false)
        #expect(doc.removeFromTopOp(alpha) == nil)
    }

    @Test func topValuesNameTilesAndTopRowsOfOneKind() throws {
        var doc = try apply(defaults, defaults.pinOp(alpha))
        doc = try apply(doc, doc.addToTopOp(beta))
        #expect(doc.topValues(kind: LayoutItemRef.workspaceKind, room: nil) == [alpha.value, beta.value])
    }

    @Test func legacyMigrationPinsEachMissingRefOnceAndIsIdempotent() throws {
        let gamma = LayoutItemRef.workspace("sess:ws_gamma")
        let start = try apply(defaults, defaults.addToTopOp(beta))
        let ops = start.legacyPinMigrationOps([alpha, beta, gamma])
        #expect(ops.count == 2, "beta is already on top")
        var doc = start
        for op in ops { doc = try apply(doc, op) }
        #expect(doc.section(SidebarLayoutDocument.pinnedSectionID)?.items.map(\.ref) == [alpha, gamma])
        #expect(doc.legacyPinMigrationOps([alpha, beta, gamma]).isEmpty)
        #expect(start.sections.allSatisfy { section in
            section.items.allSatisfy { doc.item($0.id) != nil }
        }, "nothing is removed")
    }
}
