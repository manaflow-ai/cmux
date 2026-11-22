/// The tops of a list's rows as a running total of their heights, and the rows a span reaches, for a list that gives
/// views only to the rows near its viewport (Leo 2026-11-18, ask-1105ee4cc6: "we draw the visible area, right?"). Pure:
/// no AppKit, no UIKit, so it runs and is tested on any platform. Building it reads each height once (values, never
/// views); a lookup is a binary search, O(log n) at 10,000 rows as at 100.
public struct RowOffsets: Equatable, Sendable {
    /// `tops[i]`: row i's top; the last entry is the list's height.
    public private(set) var tops: [Double]

    /// The tops of `count` rows of `height(i)` each (a row's own gap, such as a hairline below it, included).
    public init(count: Int, height: (Int) -> Double) {
        var tops = [Double]()
        tops.reserveCapacity(count + 1)
        var y = 0.0
        for index in 0..<count {
            tops.append(y)
            y += height(index)
        }
        tops.append(y)
        self.tops = tops
    }

    public var count: Int { tops.count - 1 }
    /// The list's height.
    public var height: Double { tops[count] }
    public func top(_ index: Int) -> Double { tops[index] }

    /// The row at `y`: the last row whose top is at or above it (the first or last row past the ends).
    public func row(at y: Double) -> Int {
        var low = 0, high = Swift.max(0, count - 1)
        while low < high {
            let mid = (low + high + 1) / 2
            if tops[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The rows `minY...maxY` reaches (a viewport and its overscan), empty when it misses the list.
    public func rows(reaching minY: Double, _ maxY: Double) -> Range<Int> {
        guard count > 0, maxY >= 0, minY <= height, minY <= maxY else { return 0..<0 }
        return row(at: minY)..<(row(at: maxY) + 1)
    }
}

/// Which mounted rows an update must drop: an id the new rows no longer list, or one whose value changed. Reads the
/// mounted rows only (a viewport's worth), never every row; `index` maps each new row's id to its place in `rows`.
public enum RowIDDiff {
    public static func stale<ID: Hashable, Row: Equatable>(mounted: [ID: Row], rows: [Row], index: [ID: Int]) -> [ID] {
        mounted.compactMap { id, row in index[id].map { rows[$0] == row } == true ? nil : id }
    }
}
