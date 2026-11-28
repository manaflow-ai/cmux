import CmuxVisibleRows
import Foundation
import Testing

/// `RowSpans` against a brute force over every row, at 100 and 10,000 rows: the same rows, reading O(log n) of them.
/// A Pinned-like block row (index 2) folds from 200 to 40 pt and opens again over 28 pt rows in a 900 pt viewport.
@Suite struct RowSpansTests {
    static let rowHeight = 28.0, open = 200.0, closed = 40.0, block = 2

    /// Row tops with the block at `blockHeight`.
    static func tops(_ count: Int, blockHeight: Double) -> [Double] {
        var tops: [Double] = [], y = 0.0
        for i in 0..<count {
            tops.append(y)
            y += i == block ? blockHeight : rowHeight
        }
        return tops
    }

    /// The most reads a binary-search answer may make: two searches per span, two spans.
    static func readBound(_ count: Int) -> Int { 4 * (Int(log2(Double(max(count, 1)))) + 2) }

    /// The rows after the block that reach `0...900` at `tops`, by a walk over every row.
    static func reachingBelow(_ tops: [Double], minY: Double = 0, maxY: Double = 900) -> Set<Int> {
        Set(tops.indices.filter { $0 > block && tops[$0] >= minY - max(open, rowHeight) && tops[$0] <= maxY })
    }

    @Test(arguments: [100, 10_000])
    func aFoldWalksNoRowOutsideTheBlock(_ count: Int) {
        for (from, to) in [(Self.open, Self.closed), (Self.closed, Self.open)] {
            let before = Self.tops(count, blockHeight: from), after = Self.tops(count, blockHeight: to)
            var read = 0
            let resize = RowSpans.resize(row: Self.block, from: from, to: to, count: count, viewportMinY: 0, maxY: 900,
                                         tallest: Self.open) { read += 1; return after[$0] }
            let revealed = Set(resize.revealed.flatMap { Array($0) })
            let expected = Self.reachingBelow(after).subtracting(Self.reachingBelow(before))
            print("row-spans fold n=\(count) \(from == Self.open ? "close" : "open"): dy=\(resize.dy) moved=\(resize.moved.count) rows (one offset) "
                + "revealed=\(revealed.count) rows read=\(read) rows walked one by one=0 bound=\(Self.readBound(count))")
            #expect(resize.dy == to - from)
            #expect(resize.moved == (Self.block + 1)..<count)
            #expect(revealed == expected, "revealed \(revealed.sorted()) != \(expected.sorted())")
            #expect(read == resize.reads && read <= Self.readBound(count), "read \(read) rows of \(count)")
            #expect(after[Self.block + 1] - before[Self.block + 1] == resize.dy)
        }
    }

    @Test(arguments: [100, 10_000])
    func aBandMountsOnlyTheRowsItShows(_ count: Int) {
        let tops = (0..<count).map { Double($0) * Self.rowHeight }
        let mid = tops[count / 2]
        for (minY, height) in [(0.0, 900.0), (mid, 900.0), (mid, 40.0)] {
            let window = RowSpans.mountWindow(visibleMinY: minY, visibleHeight: height, overscan: 84)
            var read = 0
            let range = RowSpans.reaching(minY: window.lowerBound, maxY: window.upperBound, tallest: Self.rowHeight, count: count,
                                          reads: &read) { tops[$0] }
            let expected = tops.indices.filter { tops[$0] + Self.rowHeight > window.lowerBound && tops[$0] <= window.upperBound }
            print("row-spans band n=\(count) at=\(Int(minY)) height=\(Int(height)): mounted=\(range.count) rows read=\(read) "
                + "rows walked one by one=0 bound=\(Self.readBound(count))")
            #expect(Set(expected).isSubset(of: Set(range)), "the window misses rows it shows")
            #expect(range.count <= expected.count + 2, "mounted \(range.count) for \(expected.count) in the window")
            #expect(window.upperBound - window.lowerBound <= height * 3, "a short band's window grew past three band heights")
            #expect(read <= Self.readBound(count))
        }
    }
}
