public import AppKit
import CmuxNextCompat

/// Which motion setting changed (``MotionChanges``).
public enum MotionChange: Sendable, Equatable {
    /// `Motion.reduceMotionOverride` or calm mode (posts `Motion.reduceMotionDidChange` too).
    case reduceMotion
    /// `ui.animationSpeed`, the master switch `ui.animations.enabled`, a category switch or calm
    /// mode (posts `Motion.speedDidChange` too).
    case speed
    /// The system Reduce Motion (Accessibility > Display).
    case systemReduceMotion
}

/// One direct subscription to every motion-setting change: Reduce Motion (the system's, calm mode
/// or the test override), `ui.animationSpeed` and the motion switches. A host outside Observation
/// that caches a motion value subscribes here instead of observing the notifications itself.
///
/// The app's instance is ``Motion/changes`` (``DesignSettings/motionChanges``). The system setting
/// is observed once for all subscribers, from the first subscription on. The instance holds its
/// subscriptions weakly: a released ``MotionSubscription`` ends on any thread, with no `deinit`.
///
/// ```swift
/// subscription = Motion.changes.subscribe { [weak self] _ in self?.redraw() }
/// ```
@MainActor
public final class MotionChanges {
    private let subscriptions = NSHashTable<MotionSubscription>.weakObjects()
    private let systemCenter: NotificationCenter
    private var system: MainActorObservation?

    /// - Parameter systemCenter: Where the system Reduce Motion change posts (the workspace's
    ///   center; tests pass their own).
    public init(systemCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.systemCenter = systemCenter
    }

    /// Calls `handler` with each motion-setting change until the returned subscription is
    /// cancelled or released. Keep it in a stored property.
    public func subscribe(_ handler: @escaping @MainActor (MotionChange) -> Void) -> MotionSubscription {
        let subscription = MotionSubscription(handler)
        subscriptions.add(subscription)
        if system == nil {
            // The system's Reduce Motion posts on the workspace's center, not the app's.
            system = MainActorObservation(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: systemCenter) {
                [weak self] in self?.send(.systemReduceMotion)
            }
        }
        return subscription
    }

    /// A cmux motion setting changed: posts its notification for the hosts that observe it, then
    /// tells every subscriber.
    func post(_ change: MotionChange) {
        switch change {
        case .reduceMotion: NotificationCenter.default.post(name: Motion.reduceMotionDidChange, object: nil)
        case .speed: NotificationCenter.default.post(name: Motion.speedDidChange, object: nil)
        case .systemReduceMotion: break
        }
        send(change)
    }

    private func send(_ change: MotionChange) {
        for subscription in subscriptions.allObjects { subscription.handler?(change) }
    }
}

/// A ``MotionChanges/subscribe(_:)`` registration; ends on ``cancel()`` or when released.
@MainActor
public final class MotionSubscription {
    fileprivate private(set) var handler: (@MainActor (MotionChange) -> Void)?

    init(_ handler: @escaping @MainActor (MotionChange) -> Void) {
        self.handler = handler
    }

    public func cancel() {
        handler = nil
    }
}
