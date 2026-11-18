/// The windowing math a list does on each scroll step, with no AppKit or UIKit, so it is tested on its own at any length
/// (`VisibleWindowTests`, on every platform the package builds for). A list's items run along one axis in order: each
/// begins at or after the one before it begins, and ends at or after the one before it ends (a tab strip's slots left
/// to right, a list's rows top to bottom). Every query is a binary search: its cost follows the items it returns, not
/// the list's length.
public enum VisibleWindow {
    /// The first index in `0..<count` that `isPast` (false for every index before it, true from it on).
    public static func partition(_ count: Int, _ isPast: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if isPast(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// The items with any part in `low...high`: item `i` spans `start(i)...end(i)`.
    public static func range(count: Int, low: Double, high: Double, start: (Int) -> Double, end: (Int) -> Double) -> Range<Int> {
        let first = partition(count) { end($0) >= low }
        return first..<max(first, partition(count) { start($0) > high })
    }

    /// What a viewport of `length` at `offset` keeps alive: itself and `overscan` viewports each side.
    public static func span(offset: Double, length: Double, overscan: Double = 1) -> ClosedRange<Double> {
        let margin = max(0, length) * max(0, overscan)
        return (offset - margin)...(offset + max(0, length) + margin)
    }

    /// The items `span(offset:length:overscan:)` reaches.
    public static func mounted(count: Int, offset: Double, length: Double, overscan: Double = 1,
                               start: (Int) -> Double, end: (Int) -> Double) -> Range<Int> {
        let span = span(offset: offset, length: length, overscan: overscan)
        return range(count: count, low: span.lowerBound, high: span.upperBound, start: start, end: end)
    }

    /// What going from mounted range `old` to `new` makes (in `new`, not `old`) and drops (in `old`, not `new`): at
    /// most one range each side of the kept part.
    public static func change(from old: Range<Int>, to new: Range<Int>) -> (added: [Range<Int>], dropped: [Range<Int>]) {
        (subtract(old, from: new), subtract(new, from: old))
    }

    /// The parts of `range` outside `other`.
    static func subtract(_ other: Range<Int>, from range: Range<Int>) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }
        guard !other.isEmpty, other.overlaps(range) else { return [range] }
        return [range.lowerBound..<min(range.upperBound, other.lowerBound), max(range.lowerBound, other.upperBound)..<range.upperBound]
            .filter { !$0.isEmpty }
    }
}

extension Range where Bound == Int {
    /// The indices in `ranges`, counted.
    public static func total(_ ranges: [Range<Int>]) -> Int { ranges.reduce(0) { $0 + $1.count } }
}
