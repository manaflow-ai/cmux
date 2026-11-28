public import Foundation

/// Host frame cadence for Ghostty's externally drained iOS renderer.
///
/// Ghostty owns cursor style, color, visibility, blink phase, and pixels. Its
/// iOS external-drain mode has no renderer-side timer, so the host periodically
/// requests a frame to let Ghostty present its current cursor phase.
public struct TerminalCursorRenderWakeState: Equatable, Sendable {
    /// Matches Ghostty's cursor blink half-period.
    public static let interval: TimeInterval = 0.5

    private var nextWake: TimeInterval?

    public init() {}

    /// Starts the cadence without claiming ownership of cursor visibility.
    public mutating func start(now: TimeInterval) {
        nextWake = now + Self.interval
    }

    /// Restarts the cadence after input resets Ghostty's blink phase.
    public mutating func reset(now: TimeInterval) {
        start(now: now)
    }

    /// Consumes one due wake and advances past every elapsed interval.
    public mutating func consumeWakeIfDue(now: TimeInterval) -> Bool {
        guard let nextWake else {
            start(now: now)
            return false
        }
        guard now >= nextWake else { return false }
        let elapsedIntervals = floor((now - nextWake) / Self.interval) + 1
        self.nextWake = nextWake + elapsedIntervals * Self.interval
        return true
    }
}
