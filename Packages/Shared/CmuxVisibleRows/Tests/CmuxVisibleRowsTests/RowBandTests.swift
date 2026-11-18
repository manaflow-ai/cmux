import CmuxVisibleRows
import Testing

/// The reveal arithmetic the popups' lists draw by (`RowOffsets`, `RowBand`, `HighlightTouch`), with no UI framework:
/// it runs on Linux. Each size prints its `row-band` line: rows in the band and rows the search read, at 100 rows as at
/// 10,000.
@Suite struct RowBandTests {
    @Test func offsetsRunTopToBottom() {
        let offsets = RowOffsets(heights: [28, 9, 44, 28])
        #expect(offsets.tops == [0, 28, 37, 81])
        #expect(offsets.length == 109)
        #expect(RowOffsets().length == 0)
    }

    @Test func theFirstRowBelowAYIsABinarySearch() {
        let offsets = RowOffsets(heights: [28, 9, 44, 28])
        #expect(offsets.firstRow(endingBelow: -5) == 0)
        #expect(offsets.firstRow(endingBelow: 0) == 0)
        #expect(offsets.firstRow(endingBelow: 27.9) == 0)
        #expect(offsets.firstRow(endingBelow: 28) == 1, "a row that ends at y is above it")
        #expect(offsets.firstRow(endingBelow: 80) == 2)
        #expect(offsets.firstRow(endingBelow: 109) == 4)
        #expect(RowOffsets().firstRow(endingBelow: 10) == 0)
    }

    @Test func theBandIsTheViewportAndOneViewportEachSide() {
        let band = RowBand(viewportTop: 1_000, height: 280)
        #expect(band == RowBand(minY: 720, maxY: 1_560))
        #expect(RowBand(viewportTop: 0, height: 280, overscan: 0) == RowBand(minY: 0, maxY: 280))
        #expect(band.relative(to: 100) == RowBand(minY: 620, maxY: 1_460))
    }

    /// The rows mounted for a 280 pt viewport of 28 pt rows: the viewport's 10 or 11 and one viewport each side, as
    /// many at 10,000 rows as at 100, wherever the list is scrolled.
    @Test(arguments: [100, 10_000])
    func theMountRangeIsTheBandsRowsAtAnyLength(_ count: Int) {
        let offsets = RowOffsets(heights: Array(repeating: 28, count: count))
        let viewport = 280.0
        var widest = 0
        for top in stride(from: 0.0, through: max(0, offsets.length - viewport), by: 13) {
            let band = RowBand(viewportTop: top, height: viewport)
            let range = offsets.rows(from: band.minY, to: band.maxY)
            let visible = offsets.rows(from: top, to: top + viewport)
            #expect(range.lowerBound <= visible.lowerBound && range.upperBound >= visible.upperBound, "the viewport's rows are in the band")
            #expect(range.count <= 3 * visible.count, "at \(top): \(range.count) rows for \(visible.count) in view")
            widest = max(widest, range.count)
        }
        print("row-band n=\(count) viewport=280 rows=28 widest-mount=\(widest)")
        #expect(widest <= 32)
    }

    /// One scroll step of one row brings in at most two rows and lets at most two go.
    @Test(arguments: [100, 10_000])
    func aOneRowScrollChangesAtMostTwoRows(_ count: Int) {
        let offsets = RowOffsets(heights: Array(repeating: 28, count: count))
        let top = min(2_000, (offsets.length - 280) / 2)
        let before = offsets.rows(from: RowBand(viewportTop: top, height: 280).minY, to: RowBand(viewportTop: top, height: 280).maxY)
        let band = RowBand(viewportTop: top + 28, height: 280)
        let after = offsets.rows(from: band.minY, to: band.maxY)
        let entered = after.filter { !before.contains($0) }.count
        let left = before.filter { !after.contains($0) }.count
        print("row-band n=\(count) one-row scroll: entered=\(entered) left=\(left)")
        #expect(entered <= 2 && left <= 2)
    }

    @Test func aHighlightMoveTouchesTheTwoRowsInvolved() {
        #expect(HighlightTouch.rows(from: "a", to: "b") == ["a", "b"])
        #expect(HighlightTouch.rows(from: nil, to: "b") == ["b"])
        #expect(HighlightTouch.rows(from: "a", to: nil) == ["a"])
        #expect(HighlightTouch.rows(from: "a", to: "a").isEmpty)
        let none: [String] = HighlightTouch.rows(from: nil, to: nil)
        #expect(none.isEmpty)
    }
}
