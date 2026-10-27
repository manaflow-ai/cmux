@testable import CmuxTabsKit
import CoreGraphics
import Testing

/// The grid builds only the cards near the screen (`GridBand`).
struct GridBandTests {
    private func pro(count: Int) -> OverviewLayout {
        OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: count)
    }

    /// 80 tabs build about a screen and a margin of cards, wherever the
    /// grid is scrolled: O(visible), not O(tabs).
    @Test func eightyTabsBuildABoundedBand() {
        let g = pro(count: 80)
        var most = 0
        var offset: CGFloat = 0
        while offset <= g.maxOffset {
            let built = g.indices(in: g.band(offset: offset))
            most = max(most, built.count)
            // Every card on screen is built.
            for i in 0..<g.count where g.screenFrame(i, offset: offset).intersects(CGRect(origin: .zero, size: g.size)) {
                #expect(built.contains(i), "card \(i) on screen at \(offset) not built")
            }
            offset += 37
        }
        #expect(most <= 16)
        #expect(most < g.count)
    }

    /// The band moves a row at a time: scrolling within a row keeps it (the
    /// grid's body does not re-run on every scroll frame).
    @Test func bandChangesOncePerRow() {
        let g = pro(count: 30)
        let start = g.band(offset: g.pitch * 2)
        #expect(g.band(offset: g.pitch * 2 + 1) == start)
        #expect(g.band(offset: g.pitch * 3 - 1) == start)
        #expect(g.band(offset: g.pitch * 3) != start)
        var changes = 0
        var last = g.band(offset: 0)
        var y: CGFloat = 0
        while y <= g.maxOffset {
            let b = g.band(offset: y)
            if b != last { changes += 1; last = b }
            y += 1
        }
        #expect(changes <= g.rows)
    }

    /// A card a row past the screen is already built (it scrolls in built),
    /// and one far below is not.
    @Test func marginBuildsTheNextRow() {
        let g = pro(count: 30)
        let band = g.band(offset: 0)
        let firstOff = (0..<g.count).first { g.card($0).minY > g.size.height } ?? 0
        #expect(band.contains(g.card(firstOff)))
        #expect(!band.contains(g.card(29)))
    }
}
