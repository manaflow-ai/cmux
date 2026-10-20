public import CoreGraphics

/// Direction the sidebar should auto-scroll while a drag hovers near an edge.
public enum SidebarAutoScrollDirection: Equatable {
    case up
    case down
}

/// Immutable plan describing how the sidebar should auto-scroll for the current
/// drag location: which direction and how many points to advance per tick.
public struct SidebarAutoScrollPlan: Equatable {
    public let direction: SidebarAutoScrollDirection
    public let pointsPerTick: CGFloat

    public init(direction: SidebarAutoScrollDirection, pointsPerTick: CGFloat) {
        self.direction = direction
        self.pointsPerTick = pointsPerTick
    }
}

/// Pure planner value that maps a drag location's distance to the viewport edges
/// into an auto-scroll plan, ramping the per-tick step between `minStep` and
/// `maxStep` as the pointer approaches the edge. Construct it with the drag
/// distances; read the result from ``plan``.
public struct SidebarDragAutoScrollPlanner: Equatable {
    /// Default distance (in points) from a viewport edge at which auto-scroll
    /// engages.
    public static let defaultEdgeInset: CGFloat = 44
    /// Default minimum per-tick scroll step (in points).
    public static let defaultMinStep: CGFloat = 2
    /// Default maximum per-tick scroll step (in points).
    public static let defaultMaxStep: CGFloat = 12

    /// The auto-scroll plan for the configured drag location, or `nil` when the
    /// pointer is outside both edge zones (or the configuration is degenerate).
    public let plan: SidebarAutoScrollPlan?

    /// Computes the auto-scroll plan for a drag location.
    ///
    /// - Parameters:
    ///   - distanceToTop: Pointer distance to the top edge, in points.
    ///   - distanceToBottom: Pointer distance to the bottom edge, in points.
    ///   - edgeInset: Distance from an edge at which auto-scroll engages.
    ///   - minStep: Minimum per-tick scroll step.
    ///   - maxStep: Maximum per-tick scroll step.
    public init(
        distanceToTop: CGFloat,
        distanceToBottom: CGFloat,
        edgeInset: CGFloat = SidebarDragAutoScrollPlanner.defaultEdgeInset,
        minStep: CGFloat = SidebarDragAutoScrollPlanner.defaultMinStep,
        maxStep: CGFloat = SidebarDragAutoScrollPlanner.defaultMaxStep
    ) {
        guard edgeInset > 0, maxStep >= minStep else {
            self.plan = nil
            return
        }
        if distanceToTop <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToTop) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            self.plan = SidebarAutoScrollPlan(direction: .up, pointsPerTick: step)
            return
        }
        if distanceToBottom <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToBottom) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            self.plan = SidebarAutoScrollPlan(direction: .down, pointsPerTick: step)
            return
        }
        self.plan = nil
    }
}
