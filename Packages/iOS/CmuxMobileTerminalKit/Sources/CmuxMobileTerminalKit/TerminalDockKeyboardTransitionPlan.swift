public import Foundation

/// The geometry action the terminal dock should take for a keyboard notification.
public enum TerminalDockKeyboardTransitionPlan: Equatable, Sendable {
    /// Preserve the current settled or in-flight geometry.
    case ignore

    /// Pin the dock directly to the requested target without animation.
    case apply

    /// Animate the dock to the requested target using the supplied duration.
    ///
    /// - Parameter duration: The effective transition duration in seconds.
    case animate(duration: TimeInterval)
}
