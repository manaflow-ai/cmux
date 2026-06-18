public import Foundation

/// Pure value model of the terminal cursor blink cycle.
///
/// Tracks visibility and the last-toggle timestamp so the render loop can ask
/// ``advance(now:)`` once per frame whether the overlay needs redrawing.
/// Holds no timers; the caller supplies monotonic time (typically
/// `CACurrentMediaTime()`). Extracted verbatim from the iOS surface view so
/// the timing logic is testable without a display link.
public struct TerminalCursorBlinkState: Equatable, Sendable {
    /// The blink half-period in seconds.
    public static let interval: TimeInterval = 0.5

    /// Whether the cursor is currently visible in the blink cycle.
    public private(set) var isVisible = true
    private var lastToggle: TimeInterval = 0

    /// Creates a blink state that starts visible.
    public init() {}

    /// Starts the blink cycle, marking the cursor visible at `now`.
    /// - Parameter now: The current monotonic time.
    public mutating func start(now: TimeInterval) {
        isVisible = true
        lastToggle = now
    }

    /// Resets the cycle to visible (call on user input so the cursor reappears).
    /// - Parameter now: The current monotonic time.
    public mutating func reset(now: TimeInterval) {
        isVisible = true
        lastToggle = now
    }

    /// Advances the cycle to `now`, toggling visibility for each elapsed
    /// half-period.
    ///
    /// - Parameter now: The current monotonic time.
    /// - Returns: `true` when visibility changed (the overlay needs redraw).
    public mutating func advance(now: TimeInterval) -> Bool {
        let elapsed = now - lastToggle
        guard elapsed >= Self.interval else { return false }
        let intervals = max(1, Int(elapsed / Self.interval))
        if intervals % 2 == 1 {
            isVisible.toggle()
        }
        lastToggle += TimeInterval(intervals) * Self.interval
        return true
    }
}
