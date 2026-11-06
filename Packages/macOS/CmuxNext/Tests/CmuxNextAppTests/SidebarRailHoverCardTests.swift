import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The rail's hover card (`sidebar.style` = rail). Lawrence 2026-10-21: "im talking about the
/// floating card... floating card relative to the workspace row". Pointing at a mark shows one
/// small card for that workspace, its top on the mark's row's top, flush with the rail,
/// following the pointer row to row, inside the window. Here: the rows the card is
/// anchored to, where the list rows' one anchor rule (`HoverCardEscapeGeometry.rowBand`, placement
/// `.besideRow`) puts the card for them, and the toggle.
@MainActor
struct SidebarRailHoverCardTests {
    private static func layout(_ count: Int = 40) -> SidebarRailLayout {
        let marks = (0..<count).map { SidebarRailMark(target: .workspace(WorkspaceID("w\($0)")), isSelected: $0 == 0, state: .idle) }
        return SidebarRailLayout(groups: [Array(marks.prefix(count / 2)), Array(marks.dropFirst(count / 2))], top: 40, available: 560)
    }

    @Test func aMarksRowIsTheRailWideAndOnePitchTallAndRowsTouch() {
        let layout = Self.layout()
        let rail = SidebarRailLayout.Metrics().railWidth
        let rows = layout.ticks.prefix(20).map { layout.row(of: $0, railWidth: rail) }
        for (tick, row) in zip(layout.ticks, rows) {
            #expect(row.minX == 0 && row.width == rail)
            #expect(row.height == layout.pitch)
            #expect(row.contains(CGPoint(x: 1, y: tick.rect.midY)), "the row holds its tick")
        }
        for (a, b) in zip(rows, rows.dropFirst()) {
            #expect(a.maxY == b.minY, "no gap between two rows of a group: the card never flickers off")
        }
    }

    /// A rail on the window's left edge at screen y `windowTop` (y up): row `index`'s band across
    /// the rail, and where the shared rule rests a card there.
    private static func card(_ layout: SidebarRailLayout, _ index: Int, windowTop: CGFloat = 700,
                             visible: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 950)) -> (row: CGRect, card: CGRect) {
        let rail = SidebarRailLayout.Metrics().railWidth
        let flipped = layout.row(of: layout.ticks[index], railWidth: rail)
        let row = CGRect(x: 0, y: windowTop - flipped.maxY, width: rail, height: flipped.height)
        let column = CGRect(x: 0, y: windowTop - 600, width: rail, height: 600)
        let band = HoverCardEscapeGeometry.rowBand(row: row, column: column)
        let geometry = HoverCardEscapeGeometry(anchor: band, cardSize: CGSize(width: 180, height: 30),
                                               visible: visible, scale: 2, alignment: .top)
        return (row, geometry.card)
    }

    @Test func aMarksCardTopIsItsRowsTopAndFlushWithTheRailAtTopMiddleAndBottom() {
        let layout = Self.layout()
        let rail = SidebarRailLayout.Metrics().railWidth
        for index in [0, 20, 39] {
            let (_, card) = Self.card(layout, index)
            // The row's top is where the mark's row starts (`rowY`), not the 2 pt tick's top.
            #expect(card.maxY == 700 - layout.ticks[index].rowY, "row \(index): the card's top is the mark's row's top")
            #expect(card.minX == rail, "row \(index): card is not flush with the rail")
        }
    }

    @Test func theCardMovesExactlyOneRowPerMark() {
        let layout = Self.layout()
        let a = Self.card(layout, 3).card, b = Self.card(layout, 4).card
        #expect(a.minY - b.minY == layout.pitch)
        #expect(a.minX == b.minX)
    }

    // MARK: Opening the full sidebar

    @Test func toggleSidebarOpensTheFullSidebarOverTheRailAndClosesItAgain() {
        let model = SidebarModel()
        model.style = .rail
        model.toggle()
        #expect(model.presentation == .shown)
        #expect(model.isRailOpen, "the toggle opens the full sidebar, not hides the rail")
        model.toggle()
        #expect(!model.isRailOpen)
        #expect(model.presentation == .shown, "the rail stays")
    }
}
