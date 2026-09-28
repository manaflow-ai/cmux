public import Foundation

/// Holds a click on an agent key hint until it can no longer become a
/// double click, so the first click of a double or triple click (which
/// selects a word or line) presses nothing.
///
/// A released single click is due once `delay`, the system double-click
/// interval, passes without another press. A press that continues the click
/// (click count 2 or more) cancels it. A new single-click press means the
/// pending click was not the start of a double click, so it is due at once.
///
/// Times are in seconds on any monotonic clock the caller supplies.
public struct AgentKeyHintDeferredPress: Sendable, Equatable {
    /// How long a released click waits for a second press.
    public let delay: TimeInterval
    /// When the pending click is due, or `nil` when none is pending.
    public private(set) var deadline: TimeInterval?

    public init(delay: TimeInterval) {
        self.delay = max(0, delay)
    }

    /// Records a released single click on a hint at `now`.
    ///
    /// - Returns: When the click is due; check it again with ``fire(at:)``
    ///   no earlier than that.
    @discardableResult
    public mutating func release(at now: TimeInterval) -> TimeInterval {
        let due = now + delay
        deadline = due
        return due
    }

    /// Records a mouse press.
    ///
    /// - Returns: Whether the pending click is due now, because this press
    ///   starts a new click rather than continuing it.
    public mutating func press(clickCount: Int) -> Bool {
        guard deadline != nil else { return false }
        deadline = nil
        return clickCount <= 1
    }

    /// Whether the pending click is due at `now`. A due click is consumed.
    public mutating func fire(at now: TimeInterval) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }

    /// Drops the pending click.
    public mutating func cancel() {
        deadline = nil
    }
}
