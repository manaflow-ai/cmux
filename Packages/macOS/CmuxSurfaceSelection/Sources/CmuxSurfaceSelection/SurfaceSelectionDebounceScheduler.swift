import CmuxFoundation
import Foundation

/// Cancellation-aware deadline source used to coalesce selection signals.
@MainActor
public protocol SurfaceSelectionDebounceScheduling: AnyObject {
    /// Replaces the pending deadline and action.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)

    /// Disarms the current deadline and drops its action.
    func cancel()
}

/// A reusable main-actor timer scheduler backed by one coalescing deadline.
@MainActor
public final class SurfaceSelectionDispatchTimerScheduler: SurfaceSelectionDebounceScheduling {
    private var action: (@MainActor () -> Void)?
    private lazy var timer = MainActorCoalescingDeadlineTimer(owner: self) { owner in
        owner.fire()
    }

    /// Creates an idle scheduler with no pending deadline.
    public init() {}

    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        self.action = action
        timer.schedule(after: delay)
    }

    public func cancel() {
        action = nil
        timer.cancel()
    }

    private func fire() {
        let action = self.action
        self.action = nil
        action?()
    }
}
