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

/// Pure planner that maps a drag location's distance to the viewport edges into
/// an auto-scroll plan, ramping the per-tick step between `minStep` and
/// `maxStep` as the pointer approaches the edge.
// lint:allow namespace-type — pure stateless policy/value namespace lifted verbatim from ContentView; no natural receiver, modernization deferred.
public enum SidebarDragAutoScrollPlanner {
    public static let edgeInset: CGFloat = 44
    public static let minStep: CGFloat = 2
    public static let maxStep: CGFloat = 12

    public static func plan(
        distanceToTop: CGFloat,
        distanceToBottom: CGFloat,
        edgeInset: CGFloat = SidebarDragAutoScrollPlanner.edgeInset,
        minStep: CGFloat = SidebarDragAutoScrollPlanner.minStep,
        maxStep: CGFloat = SidebarDragAutoScrollPlanner.maxStep
    ) -> SidebarAutoScrollPlan? {
        guard edgeInset > 0, maxStep >= minStep else { return nil }
        if distanceToTop <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToTop) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .up, pointsPerTick: step)
        }
        if distanceToBottom <= edgeInset {
            let normalized = max(0, min(1, (edgeInset - distanceToBottom) / edgeInset))
            let step = minStep + ((maxStep - minStep) * normalized)
            return SidebarAutoScrollPlan(direction: .down, pointsPerTick: step)
        }
        return nil
    }
}
