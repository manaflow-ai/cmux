public import CoreGraphics
import Foundation

/// Produces deterministic terminal-dock actions from keyboard transition geometry.
public struct TerminalDockKeyboardTransitionPlanner: Sendable {
    /// Creates a stateless terminal-dock keyboard transition planner.
    public init() {}

    /// Selects how the dock should respond to a keyboard transition notification.
    ///
    /// A real UIKit duration is preserved. When UIKit supplies zero during an
    /// interrupted animation, the planner scales the last real duration by the
    /// remaining occupancy distance, matching the hardened agent-chat behavior.
    ///
    /// - Parameter input: Current presentation geometry and notification target data.
    /// - Returns: The geometry action for the terminal dock.
    public func plan(
        for input: TerminalDockKeyboardTransitionInput
    ) -> TerminalDockKeyboardTransitionPlan {
        let remainingDistance = abs(input.targetOccupancy - input.visibleOccupancy)
        if remainingDistance <= 0.5, !input.isAnimating {
            return .ignore
        }
        if input.isAnimating,
           abs(input.targetOverlap - input.activeTargetOverlap) <= 0.5 {
            return .ignore
        }
        guard remainingDistance > 0.5 else {
            return .apply
        }
        if input.notificationDuration > 0 {
            return .animate(duration: input.notificationDuration)
        }

        let effectiveDuration: TimeInterval
        if input.isAnimating {
            let referenceDistance = max(
                input.activeTargetOverlap,
                input.targetOverlap,
                input.visibleOccupancy,
                input.targetOccupancy
            )
            if referenceDistance > 0.5 {
                let remainingFraction = min(max(remainingDistance / referenceDistance, 0.15), 1)
                effectiveDuration = max(
                    1.0 / 60.0,
                    input.lastTransitionDuration * TimeInterval(remainingFraction)
                )
            } else {
                effectiveDuration = 0
            }
        } else {
            effectiveDuration = input.lastTransitionDuration
        }

        guard effectiveDuration > 0 else {
            return .apply
        }
        return .animate(duration: effectiveDuration)
    }

    /// Converts visible bottom occupancy back to the overlap model used by the surface.
    ///
    /// ``TerminalLetterboxGeometry/keyboardOccupancy(keyboardHeight:bottomSafeAreaInset:)``
    /// uses the safe area whenever overlap is zero, so occupancy at or immediately
    /// above that boundary is represented by zero rather than a small overlap.
    ///
    /// - Parameters:
    ///   - visibleOccupancy: Presentation-derived bottom occupancy in points.
    ///   - bottomSafeAreaInset: The resolved bottom safe-area inset in points.
    /// - Returns: The overlap value that best reproduces the visible occupancy.
    public func pinnedOverlap(
        forVisibleOccupancy visibleOccupancy: CGFloat,
        bottomSafeAreaInset: CGFloat
    ) -> CGFloat {
        visibleOccupancy > bottomSafeAreaInset + 0.5 ? visibleOccupancy : 0
    }
}
