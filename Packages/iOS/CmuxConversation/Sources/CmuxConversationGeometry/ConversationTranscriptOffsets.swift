import CoreGraphics

/// The transcript's row offsets: each row's extent (the gap above it plus
/// its height) in a Fenwick tree of prefix sums. A row's top, the row at an
/// offset and a change to one row each cost O(log n), so a layout pass
/// touches the rows it places or measures, never every row of the
/// conversation (Leo, 2026-11-18: "we draw the visible area, right?").
///
/// A row is fresh when it was measured in the current epoch. Forgetting
/// every measurement (a width or text size change) only moves the epoch:
/// the old values stay as estimates until the layout measures the row
/// again, as it comes into view.
public struct ConversationTranscriptOffsets: Sendable {
    private var spacings: [CGFloat] = []
    private var heights: [CGFloat] = []
    /// The epoch each row was measured in; 0 for an estimate.
    private var stamps: [UInt32] = []
    /// 1-based Fenwick tree over the extents; `tree[0]` is unused.
    private var tree: [CGFloat] = [0]
    private var epoch: UInt32 = 1
    /// Rows not measured in this epoch (estimates).
    public private(set) var staleCount = 0

    public init() {}

    public var count: Int { heights.count }

    /// Every row's extent, from the first row's top to the last row's bottom.
    public var total: CGFloat { prefix(count) }

    public func height(at index: Int) -> CGFloat { heights[index] }

    /// The gap above row `index` (none above the first row).
    public func spacing(before index: Int) -> CGFloat { index == 0 ? 0 : spacings[index] }

    public func isFresh(_ index: Int) -> Bool { stamps[index] == epoch }

    /// Row `index`'s top, from the first row's top.
    public func top(of index: Int) -> CGFloat { prefix(index + 1) - heights[index] }

    /// Row `index`'s bottom, from the first row's top.
    public func bottom(of index: Int) -> CGFloat { prefix(index + 1) }

    /// The extents of rows `0..<end`.
    public func prefix(_ end: Int) -> CGFloat {
        var k = end
        var sum: CGFloat = 0
        while k > 0 {
            sum += tree[k]
            k &= k - 1
        }
        return sum
    }

    /// The first row whose bottom is below `y` (from the first row's top),
    /// or `count` when no row's is.
    public func firstRow(endingBelow y: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        var position = 0
        var remaining = y
        var step = 1 << (Int.bitWidth - 1 - count.leadingZeroBitCount)
        while step > 0 {
            let next = position + step
            if next <= count, tree[next] <= remaining {
                position = next
                remaining -= tree[next]
            }
            step >>= 1
        }
        return position
    }

    // MARK: Changes

    /// `count` rows, each the estimate `extent`, none measured.
    public mutating func reset(count: Int, estimate extent: CGFloat) {
        spacings = Array(repeating: 0, count: count)
        heights = Array(repeating: extent, count: count)
        stamps = Array(repeating: 0, count: count)
        staleCount = count
        rebuild(from: 0)
    }

    /// Forgets every measurement at once; the values stay as estimates.
    public mutating func invalidateAll() {
        if epoch == .max {
            // Once per four billion invalidations: no stamp may match again.
            stamps = Array(repeating: 0, count: count)
            epoch = 1
        } else {
            epoch += 1
        }
        staleCount = count
    }

    /// Row `index` was measured.
    public mutating func setMeasured(_ index: Int, spacing: CGFloat, height: CGFloat) {
        let old = extent(index)
        if stamps[index] != epoch {
            stamps[index] = epoch
            staleCount -= 1
        }
        spacings[index] = spacing
        heights[index] = height
        add(extent(index) - old, at: index)
    }

    /// Only the gap above row `index` was measured (the row above changed).
    public mutating func setSpacing(_ index: Int, _ spacing: CGFloat) {
        let old = extent(index)
        spacings[index] = spacing
        add(extent(index) - old, at: index)
    }

    /// A batch of row edits in UIKit's order: `deleted` (old indices) are
    /// removed first, then `inserted` (new indices) go in, in ascending
    /// order, as estimates of `extent`. Returns the new indices of the rows
    /// left in place whose row above changed (the row after a deleted or an
    /// inserted one), whose gap above needs measuring again. The cost is the
    /// edits plus moving the rows after the first edit, as an array insert
    /// does; nothing is measured.
    public mutating func apply(deleted: [Int], inserted: [Int], estimate extent: CGFloat) -> [Int] {
        let deleted = Array(Set(deleted)).sorted()
        let inserted = Array(Set(inserted)).sorted()
        var lowest = count
        let deletedRuns = Self.runs(deleted)
        // Deletions, in runs from the last, so the indices still hold.
        for run in deletedRuns.reversed() {
            for index in run where stamps[index] != epoch { staleCount -= 1 }
            spacings.removeSubrange(run)
            heights.removeSubrange(run)
            stamps.removeSubrange(run)
            lowest = min(lowest, run.lowerBound)
        }
        // The row that followed each deleted run, where it is now.
        var followers: [Int] = []
        var removedBefore = 0
        for run in deletedRuns {
            followers.append(run.lowerBound - removedBefore)
            removedBefore += run.count
        }
        for run in Self.runs(inserted) {
            spacings.insert(contentsOf: repeatElement(0, count: run.count), at: run.lowerBound)
            heights.insert(contentsOf: repeatElement(extent, count: run.count), at: run.lowerBound)
            stamps.insert(contentsOf: repeatElement(0, count: run.count), at: run.lowerBound)
            staleCount += run.count
            lowest = min(lowest, run.lowerBound)
            for k in followers.indices where followers[k] >= run.lowerBound { followers[k] += run.count }
            followers.append(run.upperBound)
        }
        rebuild(from: lowest)
        let insertedSet = Set(inserted)
        return Set(followers).filter { $0 < count && !insertedSet.contains($0) }.sorted()
    }

    // MARK: Tree

    private func extent(_ index: Int) -> CGFloat {
        (index == 0 ? 0 : spacings[index]) + heights[index]
    }

    private mutating func add(_ delta: CGFloat, at index: Int) {
        guard delta != 0 else { return }
        var k = index + 1
        while k < tree.count {
            tree[k] += delta
            k += k & -k
        }
    }

    /// Rebuilds the tree for the rows from `start` on (the nodes for rows
    /// before it cover only those rows and stay): appended one by one when
    /// they are few (an edit near the newest message), in one linear pass
    /// otherwise (a page landing at the top).
    private mutating func rebuild(from start: Int) {
        let n = count
        let start = min(start, n, tree.count - 1)
        if start == 0 || (n - start) * 8 > n {
            tree = [CGFloat](repeating: 0, count: n + 1)
            for index in 0..<n { tree[index + 1] = extent(index) }
            for k in stride(from: 1, through: n, by: 1) {
                let parent = k + (k & -k)
                if parent <= n { tree[parent] += tree[k] }
            }
            return
        }
        tree.removeSubrange((start + 1)...)
        for index in start..<n {
            let k = index + 1
            tree.append(extent(index) + prefix(k - 1) - prefix(k - (k & -k)))
        }
    }

    /// Sorted unique indices as contiguous runs.
    private static func runs(_ sorted: [Int]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for index in sorted {
            if let last = result.last, last.upperBound == index {
                result[result.count - 1] = last.lowerBound..<(index + 1)
            } else {
                result.append(index..<(index + 1))
            }
        }
        return result
    }
}
