/// A one-shot deadline that the host injects; the renderer uses it to
/// clean up after animations end (event-driven, never repeating). The Mac
/// host adapts CmuxNext's `DemandTimer`; the iOS host passes its own
/// one-shot timer. Tests pass a deadline they fire by hand. The renderer
/// itself never sleeps or polls.
@MainActor
public protocol HomeDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void)
    /// Drops a pending deadline.
    func cancel()
}
