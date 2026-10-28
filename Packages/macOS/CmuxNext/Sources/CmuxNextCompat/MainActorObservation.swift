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

    /// Observes `name` and hands the main-actor handler the value `read` takes from each notification.
    ///
    /// `read` and `handler` both run inside this type's one main-delivery proof, on the same delivery,
    /// so the value may be any type, `Sendable` or not (an `NSMenu`, an `NSWindow`): no caller needs a
    /// box to carry it from the notification to the handler.
    ///
    /// ```swift
    /// MainActorObservation(NSMenu.didBeginTrackingNotification, read: { $0.object as? NSMenu }) { menu in
    ///     self.tracked = menu
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name: The notification to observe.
    ///   - object: Only notifications this object posts; nil for every sender.
    ///   - center: The center to observe.
    ///   - read: Reads what the handler needs from the notification, on the main actor.
    ///   - handler: Main-actor work with the value `read` returned.
    public init<Value>(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        center: NotificationCenter = .default,
        read: @escaping @MainActor (Notification) -> Value,
        _ handler: @escaping @MainActor (Value) -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: .main) { note in
            // crash-allow: the center delivers on the main queue (queue: .main) and the notification is read only inside the assumeIsolated below, on this same delivery, so it never crosses actors.
            nonisolated(unsafe) let note = note
            // main-proof: the observer is registered on the main queue (queue: .main).
            MainActor.assumeIsolated { handler(read(note)) }
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
