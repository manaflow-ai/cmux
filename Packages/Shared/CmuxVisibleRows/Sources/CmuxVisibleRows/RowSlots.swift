/// A windowed list's row geometry without views (Leo 2026-11-18, ask-1105ee4cc6: "we draw the visible area"): each
/// row's extent and top as prefix sums from `start`, the row under a point by binary search, and the rows a viewport
/// and its overscan reach. A list keeps one, gives views only to `range(...)`, and restacks from the first row whose
/// extent changed, so a scroll step or one row's change never walks the list.
public struct RowSlots: Sendable, Equatable {
    /// Where the first row starts (the list's top padding).
    public let start: Double
    public private(set) var tops: [Double] = []
    public private(set) var extents: [Double] = []

    public init(start: Double = 0) { self.start = start }

    public var count: Int { extents.count }
    /// Where the last row ends, or `start` with no rows.
    public var end: Double { extents.isEmpty ? start : tops[tops.count - 1] + extents[extents.count - 1] }

    /// Every row's extent, stacked from the top.
    public mutating func reset(_ extents: [Double]) {
        self.extents = extents
        tops = Array(repeating: 0, count: extents.count)
        restack(from: 0)
    }

    /// Sets row `index`'s extent without moving the rows under it; true when it changed. Call `restack(from:)` once
    /// after a batch.
    @discardableResult
    public mutating func set(_ index: Int, extent: Double) -> Bool {
        guard extents[index] != extent else { return false }
        extents[index] = extent
        return true
    }

    /// Restacks the tops of rows `start...` from the row above them.
    public mutating func restack(from first: Int) {
        guard first < extents.count else { return }
        var y = first == 0 ? start : tops[first - 1] + extents[first - 1]
        for index in first..<extents.count {
            tops[index] = y
            y += extents[index]
        }
    }

    /// The row whose slot holds `y`, or the first or last row past either end; 0 with no rows.
    public func index(at y: Double) -> Int {
        guard !tops.isEmpty else { return 0 }
        var low = 0, high = tops.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if tops[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The rows a viewport `height` tall at `top` reaches, with `overscan` viewports each side.
    public func range(top: Double, height: Double, overscan: Double = 1) -> Range<Int> {
        guard !extents.isEmpty else { return 0..<0 }
        let first = index(at: top - overscan * height), last = index(at: top + (1 + overscan) * height)
        return first..<(last + 1)
    }
}

/// Which keyed rows a new snapshot of a list changed: only the `candidates` (the rows a list has views or
/// measurements for) are compared, never the whole list.
public enum RowKeyDiff {
    /// The candidates still in `index` whose item is the same in `old` and `items`; a candidate gone or changed is not.
    public static func unchanged<Item: Equatable>(_ candidates: some Sequence<String>, old: [String: Item],
                                                   index: [String: Int], items: [Item]) -> Set<String> {
        var kept = Set<String>()
        for key in candidates {
            guard let at = index[key], let before = old[key], before == items[at] else { continue }
            kept.insert(key)
        }
        return kept
    }
}
