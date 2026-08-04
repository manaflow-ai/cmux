public import CoreGraphics
public import Foundation

/// Describes the current and requested geometry for one terminal-dock keyboard transition.
public struct TerminalDockKeyboardTransitionInput: Sendable {
    /// The keyboard overlap requested by the current UIKit notification.
    public var targetOverlap: CGFloat

    /// The real duration supplied by UIKit, or zero when UIKit omitted one.
    public var notificationDuration: TimeInterval

    /// The dock's current on-screen bottom occupancy, measured from presentation geometry.
    public var visibleOccupancy: CGFloat

    /// The dock's requested bottom occupancy after applying the notification target.
    public var targetOccupancy: CGFloat

    /// Whether a terminal-dock keyboard animation is currently active.
    public var isAnimating: Bool

    /// The overlap targeted by the active animation when ``isAnimating`` is true.
    public var activeTargetOverlap: CGFloat

    /// The most recent nonzero UIKit keyboard-transition duration.
    public var lastTransitionDuration: TimeInterval

    /// Creates a keyboard-transition planning input.
    ///
    /// - Parameters:
    ///   - targetOverlap: The keyboard overlap requested by the current notification.
    ///   - notificationDuration: The real UIKit duration, or zero when omitted.
    ///   - visibleOccupancy: The dock's presentation-derived bottom occupancy.
    ///   - targetOccupancy: The requested bottom occupancy at the notification target.
    ///   - isAnimating: Whether a terminal-dock keyboard animation is active.
    ///   - activeTargetOverlap: The overlap targeted by the active animation.
    ///   - lastTransitionDuration: The most recent nonzero UIKit duration.
    public init(
        targetOverlap: CGFloat,
        notificationDuration: TimeInterval,
        visibleOccupancy: CGFloat,
        targetOccupancy: CGFloat,
        isAnimating: Bool,
        activeTargetOverlap: CGFloat,
        lastTransitionDuration: TimeInterval
    ) {
        self.targetOverlap = targetOverlap
        self.notificationDuration = notificationDuration
        self.visibleOccupancy = visibleOccupancy
        self.targetOccupancy = targetOccupancy
        self.isAnimating = isAnimating
        self.activeTargetOverlap = activeTargetOverlap
        self.lastTransitionDuration = lastTransitionDuration
    }
}
