/// The arithmetic of drawing only the rows in view, with no UI framework (Leo 2026-11-18, ask-1105ee4cc6: "we draw
/// the visible area, right?"). A list keeps its rows' offsets, known before any row view exists; each event asks which
/// rows meet the viewport and its overscan (a binary search, never a pass over every row) and which rows a highlight
/// move touches (at most two). The macOS popups' lists (NativePopupWindowLayout) read it; it runs on Linux.
public struct RowOffsets: Equatable, Sendable {
    /// Each row's top, from the run's top, and its height.
    public private(set) var tops: [Double] = []
    public private(set) var heights: [Double] = []

    public init(heights: [Double] = []) {
        tops.reserveCapacity(heights.count)
        var cursor = 0.0
        for height in heights {
            tops.append(cursor)
            cursor += height
        }
        self.heights = heights
    }

    public var count: Int { tops.count }
    /// The run's length: the last row's bottom.
    public var length: Double { tops.last.map { $0 + heights[heights.count - 1] } ?? 0 }

    /// The first row whose bottom is below `y` (a row that ends at `y` is above it); `count` when none is.
    public func firstRow(endingBelow y: Double) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid] + heights[mid] <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The rows that meet `minY..<maxY`, in order.
    public func rows(from minY: Double, to maxY: Double) -> Range<Int> {
        let first = firstRow(endingBelow: minY)
        var last = first
        // Rows past the first are walked only while they still start inside the band (the band's rows, no more).
        while last < count, tops[last] < maxY { last += 1 }
        return first..<max(first, last)
    }
}

/// The band a list draws rows in: its viewport and `overscan` viewports above and below.
public struct RowBand: Equatable, Sendable {
    public var minY: Double
    public var maxY: Double

    public init(minY: Double, maxY: Double) {
        self.minY = minY
        self.maxY = maxY
    }

    /// The viewport at `top`, `height` tall, with `overscan` of its height each side.
    public init(viewportTop top: Double, height: Double, overscan: Double = 1) {
        self.init(minY: top - height * overscan, maxY: top + height * (1 + overscan))
    }

    /// The band seen from a run whose top is at `offset` in the document.
    public func relative(to offset: Double) -> RowBand { RowBand(minY: minY - offset, maxY: maxY - offset) }
}

/// The rows a highlight move redraws: the one that had it and the one that has it, at most two, none when it stays.
public enum HighlightTouch {
    public static func rows<ID: Hashable>(from old: ID?, to new: ID?) -> [ID] {
        guard old != new else { return [] }
        return [old, new].compactMap(\.self)
    }
}
