import CmuxVisibleRows
import Foundation
import Testing

/// `VisibleRowsIndex` (the Priority view's offsets and searches) at 100 and 10,000 rows, on Linux as on macOS: the rows
/// to draw stay within the viewport and one each side, and one row's change moves no other row. Each case prints its
/// cost in µs per update ("visible-rows-index").
struct VisibleRowsIndexTests {
    struct Row: Equatable { var id: String, title: String, tall: Bool }

    static func rows(_ count: Int) -> [Row] {
        (0..<count).map { Row(id: "r\($0)", title: "chat \($0)", tall: $0.isMultiple(of: 3)) }
    }

    static func index(_ rows: [Row]) -> VisibleRowsIndex<String> {
        VisibleRowsIndex(rows, id: \.id) { $0.tall ? 52 : 28 }
    }

    static func micros(_ duration: Duration, per updates: Int) -> Double {
        (Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12) / Double(updates)
    }

    @Test(arguments: [100, 10_000])
    func theDrawnRangeIsTheViewportAndOneEachSide(count: Int) {
        let index = Self.index(Self.rows(count))
        let viewport: CGFloat = 400
        // The shortest row is 28 points: three viewports of them, and a partial row at each end.
        let bound = Int((viewport * 3 / 28).rounded(.up)) + 2
        let updates = 1_000
        var widest = 0, top: CGFloat = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for step in 0..<updates {
                top = index.totalHeight * CGFloat(step) / CGFloat(updates)
                let range = index.drawnRange(top: top, height: viewport)
                widest = max(widest, range.count)
                #expect(range.contains(index.row(below: top)) || index.row(below: top) == count)
            }
        }
        print("visible-rows-index n=\(count) case=scroll widest_range=\(widest) bound=\(bound) "
            + "us_per_update=\(String(format: "%.3f", Self.micros(elapsed, per: updates)))")
        #expect(widest <= bound, "drew \(widest) rows of \(count); at most \(bound)")
        #expect(index.drawnRange(top: 0, height: 0).isEmpty)
        #expect(VisibleRowsIndex<String>().drawnRange(top: 0, height: viewport).isEmpty)
    }

    @Test(arguments: [100, 10_000])
    func oneRowsChangeMovesNoOtherRow(count: Int) {
        var rows = Self.rows(count)
        let before = Self.index(rows)
        let updates = 50
        var after = before
        let elapsed = ContinuousClock().measure {
            for update in 0..<updates {
                rows[1].title = "renamed \(update)"
                after = Self.index(rows)
            }
        }
        // Same heights: every top and place is unchanged, so no row is laid out again.
        #expect(after == before)
        // One row grows: only the rows below it move, by its growth.
        rows[count / 2].tall.toggle()
        let grown = Self.index(rows)
        let moved = (0...count).filter { grown.tops[$0] != before.tops[$0] }
        #expect(moved == Array((count / 2 + 1)...count))
        #expect(grown.places == before.places)
        print("visible-rows-index n=\(count) case=reindex rows_moved_by_retitle=0 rows_moved_by_resize=\(moved.count - 1) "
            + "us_per_update=\(String(format: "%.1f", Self.micros(elapsed, per: updates)))")
    }

    @Test(arguments: [100, 10_000])
    func theDropSlotMatchesAWalkOfEveryRow(count: Int) {
        let index = Self.index(Self.rows(count))
        let walk = { (from: Int, middle: CGFloat) in
            (0..<count).filter { $0 != from && (index.tops[$0] + index.tops[$0 + 1]) / 2 < middle }.count
        }
        let probes = [(0, 1), (count / 2, count / 3), (count - 1, count / 2), (count / 3, count - 1)]
        for (from, over) in probes {
            let middle = (index.tops[over] + index.tops[over + 1]) / 2 + 1
            #expect(index.dropSlot(from: from, middle: middle) == walk(from, middle))
        }
        let updates = 1_000
        var slot = 0
        let elapsed = ContinuousClock().measure {
            for step in 0..<updates { slot &+= index.dropSlot(from: count / 2, middle: index.totalHeight * CGFloat(step) / 1_000) }
        }
        print("visible-rows-index n=\(count) case=drag-slot us_per_update=\(String(format: "%.3f", Self.micros(elapsed, per: updates))) checksum=\(slot)")
    }
}
