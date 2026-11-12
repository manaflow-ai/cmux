public import AppKit
public import Foundation
public import CmuxNextDesignTokens

extension MotionGate {
    /// How long an agent cursor glide whose cmux-cua plan takes `natural`
    /// seconds plays: ``MotionTunables/agentCursorGlideScale`` of it, at most
    /// ``MotionTunables/agentCursorGlideMax``, scaled by `ui.animationSpeed`.
    /// Nil when movement does not animate (this gate's category or the master
    /// switch off, Reduce Motion, speed off, a live resize of `window`): the cursor then moves at once.
    ///
    /// - Parameters:
    ///   - natural: The plan's own duration, in seconds.
    ///   - window: The window that shows the cursor.
    /// - Returns: The duration to play, or nil to move at once.
    public func agentCursorGlideDuration(_ natural: TimeInterval, in window: NSWindow?) -> TimeInterval? {
        guard animatesMovement(in: window), natural > 0 else { return nil }
        let short = min(natural * MotionTunables.agentCursorGlideScale.value, MotionTunables.agentCursorGlideMax.value)
        return short * speed.timeScale
    }
}
