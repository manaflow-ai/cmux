import Foundation

/// A list's row offsets and the rows to draw, with no UI framework: each row's top as a prefix sum of the row heights
/// (`tops`), each id's place (`places`), and binary searches over `tops` for the rows in a viewport and the slot a held
/// row drops into. Built once per change of the list (one pass over its rows); every query after that is a search,
/// not a walk, so a scroll or a drag costs the same at 100 rows as at 10,000.
public struct VisibleRowsIndex<ID: Hashable & Sendable>: Equatable, Sendable {
    /// Each row's top in order, then the rows' full height: row `i` spans `tops[i]..<tops[i + 1]`.
    public private(set) var tops: [CGFloat] = [0]
    /// Each id's place in the list.
    public private(set) var places: [ID: Int] = [:]

    public init() {}

    /// The index of `rows` in order, each `height(row)` tall.
    public init<Rows: Collection>(_ rows: Rows, id: (Rows.Element) -> ID, height: (Rows.Element) -> CGFloat) {
        tops.reserveCapacity(rows.count + 1)
        places.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            places[id(row)] = index
            y += height(row)
            tops.append(y)
        }
    }

    public var count: Int { tops.count - 1 }
    public var totalHeight: CGFloat { tops[tops.count - 1] }

    /// The first row whose bottom is below `y` (`count` past the last).
    public func row(below y: CGFloat) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid + 1] <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The rows in a viewport `height` tall whose top is at `top`, and one viewport above and below it.
    public func drawnRange(top: CGFloat, height: CGFloat) -> Range<Int> {
        guard count > 0, height > 0 else { return 0..<0 }
        let lower = row(below: top - height)
        let upper = min(count, row(below: top + 2 * height) + 1)
        return lower..<max(lower, upper)
    }

    /// The slot a held row at `from` whose middle is at `middle` drops into: the other rows whose middle is above it.
    /// The middles rise in order, so it is a search of `tops`, not a walk of every row.
    public func dropSlot(from: Int, middle: CGFloat) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if (tops[mid] + tops[mid + 1]) / 2 < middle { low = mid + 1 } else { high = mid }
        }
        return low - ((tops[from] + tops[from + 1]) / 2 < middle ? 1 : 0)
    }
}
