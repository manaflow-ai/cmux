import CoreGraphics
import Foundation

public struct CodexTrajectoryHeightIndex: Sendable {
    public private(set) var heights: [CGFloat]
    private var tree: [CGFloat]

    public init(heights: [CGFloat] = []) {
        self.heights = heights.map { max(0, $0) }
        self.tree = Array(repeating: 0, count: heights.count + 1)
        for index in self.heights.indices {
            add(self.heights[index], at: index)
        }
    }

    public var count: Int {
        heights.count
    }

    public var isEmpty: Bool {
        heights.isEmpty
    }

    public var totalHeight: CGFloat {
        prefixSum(upTo: heights.count)
    }

    public mutating func append(_ height: CGFloat) {
        let newHeight = max(0, height)
        let oldCount = heights.count
        let oldTotal = totalHeight
        heights.append(newHeight)
        tree.append(0)

        let oneBasedIndex = oldCount + 1
        let rangeLength = oneBasedIndex & -oneBasedIndex
        let rangeStart = oneBasedIndex - rangeLength
        tree[oneBasedIndex] = oldTotal - prefixSum(upTo: rangeStart) + newHeight
    }

    public mutating func replaceAll(with heights: [CGFloat]) {
        self = CodexTrajectoryHeightIndex(heights: heights)
    }

    public mutating func update(index: Int, height: CGFloat) {
        guard heights.indices.contains(index) else { return }
        let newHeight = max(0, height)
        let delta = newHeight - heights[index]
        heights[index] = newHeight
        add(delta, at: index)
    }

    public func prefixSum(upTo endIndex: Int) -> CGFloat {
        guard endIndex > 0 else { return 0 }
        var index = min(endIndex, heights.count)
        var result: CGFloat = 0
        while index > 0 {
            result += tree[index]
            index -= index & -index
        }
        return result
    }

    public func height(at index: Int) -> CGFloat? {
        guard heights.indices.contains(index) else { return nil }
        return heights[index]
    }

    public func index(containingOffset offset: CGFloat) -> Int? {
        guard !heights.isEmpty else { return nil }
        if offset <= 0 {
            return 0
        }
        if totalHeight <= 0 {
            return 0
        }
        if offset >= totalHeight {
            return heights.count - 1
        }

        var index = 0
        var bitMask = highestPowerOfTwoNotGreaterThan(heights.count)
        var remaining = offset

        while bitMask != 0 {
            let next = index + bitMask
            if next <= heights.count, tree[next] <= remaining {
                index = next
                remaining -= tree[next]
            }
            bitMask >>= 1
        }

        return min(index, heights.count - 1)
    }

    public func indexRange(intersectingOffset offset: CGFloat, length: CGFloat, overscan: CGFloat = 0) -> Range<Int> {
        guard !heights.isEmpty, length > 0 else { return 0..<0 }
        let lower = max(0, offset - overscan)
        let upper = min(totalHeight, offset + length + overscan)
        guard upper > lower,
              let start = index(containingOffset: lower),
              let end = index(containingOffset: max(lower, upper.nextDown)) else {
            return 0..<0
        }
        return start..<min(end + 1, heights.count)
    }

    private mutating func add(_ delta: CGFloat, at zeroBasedIndex: Int) {
        var index = zeroBasedIndex + 1
        while index < tree.count {
            tree[index] += delta
            index += index & -index
        }
    }

    private mutating func rebuild() {
        tree = Array(repeating: 0, count: heights.count + 1)
        for index in heights.indices {
            add(heights[index], at: index)
        }
    }

    private func highestPowerOfTwoNotGreaterThan(_ value: Int) -> Int {
        var power = 1
        while power << 1 <= value {
            power <<= 1
        }
        return power
    }
}
