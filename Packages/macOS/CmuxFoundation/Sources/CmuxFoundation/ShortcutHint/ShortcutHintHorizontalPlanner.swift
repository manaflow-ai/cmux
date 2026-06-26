public import CoreGraphics

/// Resolves overlaps among titlebar shortcut-hint intervals by sliding their
/// right edges leftward, processing right to left so adjacent hints keep
/// ``minSpacing`` between them, then shifts the whole row right if it would
/// cross ``minLeadingEdge``.
public struct ShortcutHintHorizontalPlanner {
    /// Closed horizontal extents of the hints to resolve, in layout order.
    public let intervals: [ClosedRange<CGFloat>]
    /// Minimum gap, in points, required between two adjacent hints.
    public let minSpacing: CGFloat
    /// Leftmost edge the resolved row may occupy; the row shifts right to honor it.
    public let minLeadingEdge: CGFloat

    /// Creates a horizontal planner for the given hint `intervals`.
    ///
    /// - Parameters:
    ///   - intervals: Closed horizontal extents to resolve, in layout order.
    ///   - minSpacing: Minimum gap between two adjacent hints.
    ///   - minLeadingEdge: Leftmost edge the resolved row may occupy.
    public init(
        intervals: [ClosedRange<CGFloat>],
        minSpacing: CGFloat = 6,
        minLeadingEdge: CGFloat = 0
    ) {
        self.intervals = intervals
        self.minSpacing = minSpacing
        self.minLeadingEdge = minLeadingEdge
    }

    /// The resolved right edge for each interval, parallel to ``intervals``.
    public var rightEdges: [CGFloat] {
        guard !intervals.isEmpty else { return [] }

        var assignedRightEdges = Array(repeating: CGFloat.zero, count: intervals.count)
        var nextMaxRight = CGFloat.greatestFiniteMagnitude

        for index in stride(from: intervals.count - 1, through: 0, by: -1) {
            let interval = intervals[index]
            let width = interval.upperBound - interval.lowerBound
            let preferredRightEdge = interval.upperBound
            let adjustedRightEdge = min(preferredRightEdge, nextMaxRight)
            assignedRightEdges[index] = adjustedRightEdge
            nextMaxRight = adjustedRightEdge - width - minSpacing
        }

        let assignedLeftEdges = zip(intervals, assignedRightEdges).map { interval, rightEdge in
            rightEdge - (interval.upperBound - interval.lowerBound)
        }
        if let minAssignedLeftEdge = assignedLeftEdges.min(), minAssignedLeftEdge < minLeadingEdge {
            let shift = minLeadingEdge - minAssignedLeftEdge
            assignedRightEdges = assignedRightEdges.map { $0 + shift }
        }

        return assignedRightEdges
    }
}
