public import Foundation

extension Motion {
    /// How long an agent cursor glide whose cmux-cua plan takes `natural`
    /// seconds plays: ``MotionTunables/agentCursorGlideScale`` of it, at most
    /// ``MotionTunables/agentCursorGlideMax``, scaled by `ui.animationSpeed`.
    /// Nil when movement does not animate (Reduce Motion, speed off, a live
    /// resize): the cursor then moves at once.
    ///
    /// - Parameter natural: The plan's own duration, in seconds.
    /// - Returns: The duration to play, or nil to move at once.
    public static func agentCursorGlideDuration(_ natural: TimeInterval) -> TimeInterval? {
        guard animatesMovement, natural > 0 else { return nil }
        let short = min(natural * MotionTunables.agentCursorGlideScale.value, MotionTunables.agentCursorGlideMax.value)
        return short * speed.timeScale
    }
}
