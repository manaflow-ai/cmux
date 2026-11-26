/// Index math for a list whose rows go down by their top edge (each row's top at or below the one before it), shared by
/// the lists that draw only what shows (Leo 2026-11-18, ask-1105ee4cc6: "we draw the visible area, right?"). Pure: no
/// AppKit, no UIKit, no views, so it runs and is tested on any platform. Every answer finds its rows by binary search and
/// visits no row one by one: it reads O(log n) rows, at 10,000 rows as at 100. `reads` counts each row it read.
// lint:allow namespace-type: pure index math over a caller's rows (a closure), shared by every windowed list; no receiver owns it.
public enum RowSpans {
    /// The rows that can intersect `minY...maxY`: those whose top is in `minY - tallest ... maxY` (`tallest`: the
    /// tallest row's height, so a tall row starting above the span still counts). `top(i)`: row i's top.
    public static func reaching(minY: Double, maxY: Double, tallest: Double, count: Int, reads: inout Int,
                                top: (Int) -> Double) -> Range<Int> {
        let low = firstIndex(count, reads: &reads) { top($0) >= minY - tallest }
        let high = firstIndex(count, reads: &reads) { top($0) > maxY }
        return low..<max(low, high)
    }

    /// The span a capped band mounts item views for: what it shows plus `overscan` past each edge, never more than one
    /// band height (a short band keeps a short window).
    public static func mountWindow(visibleMinY: Double, visibleHeight: Double, overscan: Double) -> ClosedRange<Double> {
        let pad = min(overscan, max(0, visibleHeight))
        return (visibleMinY - pad)...(visibleMinY + max(0, visibleHeight) + pad)
    }

    /// One row's height change, spliced (a top section's fold: its block row closes or opens).
    public struct Resize: Equatable, Sendable {
        /// How far every row after the resized one moves.
        public var dy: Double
        /// The rows that move by `dy`: every row after the resized one, as one offset (no row is visited for it).
        public var moved: Range<Int>
        /// The rows after the resized one that reach the viewport now and did not before: the ones that need views.
        public var revealed: [Range<Int>]
        /// Rows the answer read (binary search probes), outside the resized row.
        public var reads: Int
    }

    /// Row `index` goes from `oldHeight` to `newHeight`. `top(i)`: row i's top after the change (the rows after `index`
    /// moved by the difference); `minY...maxY`: the viewport (with its overscan), which does not move.
    public static func resize(row index: Int, from oldHeight: Double, to newHeight: Double, count: Int, viewportMinY minY: Double,
                              maxY: Double, tallest: Double, top: (Int) -> Double) -> Resize {
        let dy = newHeight - oldHeight
        let after = min(count, index + 1)..<count
        var reads = 0
        // Rows read past the resized one only: an index in `after` maps to the rows below it.
        func below(_ i: Int) -> Double { top(after.lowerBound + i) }
        let now = reaching(minY: minY, maxY: maxY, tallest: tallest, count: after.count, reads: &reads, top: below)
        // Before the change the same rows sat `dy` higher or lower: the ones that reached the viewport then.
        let before = reaching(minY: minY + dy, maxY: maxY + dy, tallest: tallest, count: after.count, reads: &reads, top: below)
        let shift = { (r: Range<Int>) in (r.lowerBound + after.lowerBound)..<(r.upperBound + after.lowerBound) }
        var revealed: [Range<Int>] = []
        if before.isEmpty {
            revealed = [now]
        } else {
            revealed = [now.lowerBound..<max(now.lowerBound, min(now.upperBound, before.lowerBound)),
                        max(now.lowerBound, before.upperBound)..<max(now.lowerBound, before.upperBound, now.upperBound)]
        }
        return Resize(dy: dy, moved: after, revealed: revealed.filter { !$0.isEmpty }.map(shift), reads: reads)
    }

    /// The first index in `0..<count` where `holds` is true (it is false, then true, along the rows); `count` if none.
    private static func firstIndex(_ count: Int, reads: inout Int, _ holds: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            reads += 1
            if holds(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
