import Foundation

/// A list's row extents (each row's height, with any gap above it) as a Fenwick tree: a row's
/// offset, the row at an offset, one row's change and an appended row each cost O(log n), so a
/// list's layout never re-sums every row for one changed height (a streamed token, a row that
/// measured itself, a row coming on screen at a new width). Building from scratch is O(n), for
/// a new set of rows only.
public struct RowOffsets: Sendable {
    /// 1-based: `tree[i]` holds the extents of rows `(i - lowbit(i)) ..< i`.
    private var tree: [Double] = [0]
    private var values: [Double] = []
    /// Tree nodes written (tests: one row's change writes O(log n) of them, never every row).
    public private(set) var writes = 0

    public init() {}

    public init(_ extents: [CGFloat]) {
        values = extents.map(Double.init)
        tree = [0] + values
        let count = values.count
        if count > 0 {
            for index in 1...count {
                let parent = index + (index & -index)
                if parent <= count { tree[parent] += tree[index] }
            }
        }
        writes += count
    }

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    /// Row `row`'s extent.
    public subscript(row: Int) -> CGFloat { CGFloat(values[row]) }

    /// Every row's extent together.
    public var total: CGFloat { offset(of: count) }

    /// The extents of the rows before `row` (`row == count`: all of them).
    public func offset(of row: Int) -> CGFloat {
        var sum = 0.0
        var index = min(row, count)
        while index > 0 {
            sum += tree[index]
            index -= index & -index
        }
        return CGFloat(sum)
    }

    /// The first row whose end (its offset plus its extent) is at or past `y`; `count` when none is.
    /// Extents must not be negative.
    public func firstRow(endingAtOrAfter y: CGFloat) -> Int {
        let target = Double(y)
        var position = 0
        var below = 0.0
        var step = 1
        while step * 2 <= count { step *= 2 }
        while step > 0 {
            let next = position + step
            if next <= count, below + tree[next] < target {
                position = next
                below += tree[next]
            }
            step /= 2
        }
        return position
    }

    /// Sets row `row`'s extent.
    public mutating func set(_ row: Int, _ extent: CGFloat) {
        let delta = Double(extent) - values[row]
        guard delta != 0 else { return }
        values[row] = Double(extent)
        var index = row + 1
        while index <= count {
            tree[index] += delta
            writes += 1
            index += index & -index
        }
    }

    /// Adds a row at the end.
    public mutating func append(_ extent: CGFloat) {
        let index = count + 1
        let low = index - (index & -index)
        // The new node covers rows low ..< index: the new row and the ones before it it spans.
        let node = Double(extent) + Double(offset(of: index - 1) - offset(of: low))
        values.append(Double(extent))
        tree.append(node)
        writes += 1
    }

    /// Drops the last `k` rows (the nodes left cover only rows that stay).
    public mutating func removeLast(_ k: Int) {
        guard k > 0 else { return }
        values.removeLast(k)
        tree.removeLast(k)
    }
}
