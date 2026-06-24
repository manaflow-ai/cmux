public import CoreGraphics

/// Packs titlebar shortcut-hint pills, modeled as horizontal intervals over the
/// controls' content coordinate space, so overlapping hints stay readable.
///
/// Two independent strategies share one planner value because both consume the
/// same `[ClosedRange<CGFloat>]` interval list produced by the titlebar layout:
///
/// - ``assignLanes(for:)`` greedily stacks overlapping intervals onto the fewest
///   vertical lanes (first-fit by left edge), returning a lane index per interval.
/// - ``assignRightEdges(for:)`` resolves horizontal crowding by sliding each
///   interval's right edge left just enough to keep `minSpacing` between
///   neighbors, then shifts the whole row right if it would cross `minLeadingEdge`.
///
/// The spacing configuration is stored on the instance so a caller constructs one
/// planner with its layout constants and reuses it, instead of threading spacing
/// through every call. Default-initialized, it reproduces the legacy per-strategy
/// defaults (`laneMinSpacing` 4, `rightEdgeMinSpacing` 6, `minLeadingEdge` 0).
public struct ShortcutHintLayoutPlanner: Sendable {
    /// Minimum horizontal gap between intervals sharing a lane in ``assignLanes(for:)``.
    public let laneMinSpacing: CGFloat

    /// Minimum horizontal gap between adjacent intervals in ``assignRightEdges(for:)``.
    public let rightEdgeMinSpacing: CGFloat

    /// The leftmost edge ``assignRightEdges(for:)`` allows; the whole row shifts
    /// right when the tightest assignment would cross it.
    public let minLeadingEdge: CGFloat

    /// Creates a planner with the spacing constants used while packing hints.
    /// - Parameters:
    ///   - laneMinSpacing: gap between same-lane intervals for lane assignment.
    ///   - rightEdgeMinSpacing: gap between neighbors for right-edge assignment.
    ///   - minLeadingEdge: leftmost edge the right-edge pass keeps intervals within.
    public init(
        laneMinSpacing: CGFloat = 4,
        rightEdgeMinSpacing: CGFloat = 6,
        minLeadingEdge: CGFloat = 0
    ) {
        self.laneMinSpacing = laneMinSpacing
        self.rightEdgeMinSpacing = rightEdgeMinSpacing
        self.minLeadingEdge = minLeadingEdge
    }

    /// Assigns each interval the lowest lane index whose last interval ends at
    /// least `laneMinSpacing` before this interval begins, opening a new lane when
    /// none fits.
    /// - Parameter intervals: hint intervals in layout order.
    /// - Returns: a lane index per interval, parallel to `intervals`.
    public func assignLanes(for intervals: [ClosedRange<CGFloat>]) -> [Int] {
        guard !intervals.isEmpty else { return [] }

        var laneMaxX: [CGFloat] = []
        var lanes: [Int] = []
        lanes.reserveCapacity(intervals.count)

        for interval in intervals {
            var lane = 0
            while lane < laneMaxX.count {
                let requiredMinX = laneMaxX[lane] + laneMinSpacing
                if interval.lowerBound >= requiredMinX {
                    break
                }
                lane += 1
            }

            if lane == laneMaxX.count {
                laneMaxX.append(interval.upperBound)
            } else {
                laneMaxX[lane] = max(laneMaxX[lane], interval.upperBound)
            }
            lanes.append(lane)
        }

        return lanes
    }

    /// Slides each interval's right edge left (walking right-to-left) so neighbors
    /// keep `rightEdgeMinSpacing`, then shifts every edge right by one amount if the
    /// tightest result would push any left edge past `minLeadingEdge`.
    /// - Parameter intervals: hint intervals in layout order.
    /// - Returns: the resolved right edge per interval, parallel to `intervals`.
    public func assignRightEdges(for intervals: [ClosedRange<CGFloat>]) -> [CGFloat] {
        guard !intervals.isEmpty else { return [] }

        var assignedRightEdges = Array(repeating: CGFloat.zero, count: intervals.count)
        var nextMaxRight = CGFloat.greatestFiniteMagnitude

        for index in stride(from: intervals.count - 1, through: 0, by: -1) {
            let interval = intervals[index]
            let width = interval.upperBound - interval.lowerBound
            let preferredRightEdge = interval.upperBound
            let adjustedRightEdge = min(preferredRightEdge, nextMaxRight)
            assignedRightEdges[index] = adjustedRightEdge
            nextMaxRight = adjustedRightEdge - width - rightEdgeMinSpacing
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
