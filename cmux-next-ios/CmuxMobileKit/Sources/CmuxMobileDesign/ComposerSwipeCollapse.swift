import CoreGraphics
import Foundation

/// Whether a drag inside a composer's text collapses it (every composer: the
/// terminal's message composer and the agent chat's). Leo, 2026-11-22:
/// "chatgpt you csn swipe down inside the composer to collapse it. we need
/// that here too."
///
/// A downward, mostly vertical drag that starts with the text at its top
/// collapses the composer (its keyboard goes down). A long draft scrolled
/// partway still scrolls up first: only a drag that began at the top counts.
/// A press held before it moves is the caret loupe or a selection, never a
/// collapse.
public struct ComposerSwipeCollapse: Equatable, Sendable {
    /// Down this far collapses, at any speed.
    public var distance: CGFloat = 24
    /// A flick this fast (points per second, downward) collapses after only
    /// `flickDistance`.
    public var flickVelocity: CGFloat = 400
    public var flickDistance: CGFloat = 8
    /// Down must beat sideways by this much (a sideways caret drag is not a swipe).
    public var verticalBias: CGFloat = 1.5
    /// A press held this long before moving is the loupe or a selection.
    public var holdLimit: TimeInterval = 0.3

    public init() {}

    /// The drag so far: `translation` and `velocity` in the view (y grows
    /// down), whether the text was at its top when the drag began, and how
    /// long the finger rested before it began to move.
    public func collapses(translation: CGPoint, velocity: CGPoint, beganAtTop: Bool, heldFor: TimeInterval) -> Bool {
        guard beganAtTop, heldFor < holdLimit else { return false }
        let down = translation.y
        guard down > 0, down >= abs(translation.x) * verticalBias else { return false }
        if down >= distance { return true }
        return down >= flickDistance && velocity.y >= flickVelocity
    }
}
