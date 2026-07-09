public import CoreGraphics

/// Packs titlebar shortcut-hint intervals into stacked lanes so overlapping
/// hints never collide. Each interval is assigned the lowest lane index whose
/// current right edge clears the interval's leading edge by ``minSpacing``.
public struct ShortcutHintLanePlanner {
    /// Closed horizontal extents of the hints to pack, in layout order.
    public let intervals: [ClosedRange<CGFloat>]
    /// Minimum gap, in points, required between two hints sharing a lane.
    public let minSpacing: CGFloat

    /// Creates a lane planner for the given hint `intervals`.
    ///
    /// - Parameters:
    ///   - intervals: Closed horizontal extents to pack, in layout order.
    ///   - minSpacing: Minimum gap between two hints sharing a lane.
    public init(intervals: [ClosedRange<CGFloat>], minSpacing: CGFloat = 4) {
        self.intervals = intervals
        self.minSpacing = minSpacing
    }

    /// The lane index assigned to each interval, parallel to ``intervals``.
    public var lanes: [Int] {
        guard !intervals.isEmpty else { return [] }

        var laneMaxX: [CGFloat] = []
        var lanes: [Int] = []
        lanes.reserveCapacity(intervals.count)

        for interval in intervals {
            var lane = 0
            while lane < laneMaxX.count {
                let requiredMinX = laneMaxX[lane] + minSpacing
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
}
