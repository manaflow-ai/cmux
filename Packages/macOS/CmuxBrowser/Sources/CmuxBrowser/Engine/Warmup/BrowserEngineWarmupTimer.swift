import Foundation

/// A one-shot, re-armable deadline used by ``BrowserEngineWarmup``.
///
/// Scheduling again replaces the pending deadline. The live implementation is
/// ``BrowserEngineWarmupClockTimer``; tests inject one they fire by hand.
@MainActor
public protocol BrowserEngineWarmupTimer: AnyObject {
    /// `true` while a deadline is pending.
    var isScheduled: Bool { get }
    /// Runs `fire` once after `delay`, replacing any pending deadline.
    /// - Parameters:
    ///   - delay: The delay from now.
    ///   - fire: The work to run on the main actor.
    func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void)
    /// Cancels the pending deadline, if any.
    func cancel()
}
