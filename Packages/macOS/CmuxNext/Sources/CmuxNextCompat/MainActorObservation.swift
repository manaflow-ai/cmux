public import Foundation

/// A NotificationCenter observer whose handler runs on the main actor and that removes itself
/// when released.
///
/// It replaces the hand-written pair `addObserver(forName:object:queue: .main) { MainActor
/// .assumeIsolated { ... } }` plus `deinit { MainActor.assumeIsolated { removeObserver } }`:
/// the main-delivery proof lives here once, and the owner's `deinit` needs nothing
/// (`NotificationCenter.removeObserver(_:)` is thread-safe, so no isolated `deinit`, which
/// macOS 14 cannot back-deploy). Keep the token in a stored property; set it to nil or call
/// ``cancel()`` to stop early.
///
/// ```swift
/// observation = MainActorObservation(NSWindow.didBecomeKeyNotification, object: window) { [weak self] in
///     self?.keyChanged()
/// }
/// ```
public final class MainActorObservation {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    /// Observes `name` from `object` (nil: any sender) on `center`, delivering on the main actor.
    ///
    /// - Parameters:
    ///   - name: The notification to observe.
    ///   - object: Only notifications this object posts; nil for every sender.
    ///   - center: The center to observe (default `NotificationCenter.default`; tests pass their own).
    ///   - handler: Main-actor work for each notification (the `Notification` is not `Sendable`;
    ///     read what you need from the poster's state, not the payload).
    public init(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        center: NotificationCenter = .default,
        _ handler: @escaping @MainActor () -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            // main-proof: the observer is registered on the main queue (queue: .main).
            MainActor.assumeIsolated { handler() }
        }
    }

    /// Stops observing now (also happens when the token is released).
    public func cancel() {
        center.removeObserver(token)
    }

    deinit {
        center.removeObserver(token)
    }
}
