import CoreGraphics

/// Converts a logical sidebar scroll direction into the document view's
/// vertical coordinate system.
enum SidebarDragAutoScrollMotion {
    static func verticalDelta(
        for plan: SidebarAutoScrollPlan,
        documentViewIsFlipped: Bool
    ) -> CGFloat {
        let directionMultiplier: CGFloat = plan.direction == .down ? 1 : -1
        let flippedMultiplier: CGFloat = documentViewIsFlipped ? 1 : -1
        return directionMultiplier * flippedMultiplier * plan.pointsPerTick
    }
}
