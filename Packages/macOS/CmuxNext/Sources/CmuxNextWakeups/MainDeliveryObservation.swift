public import Foundation

/// A NotificationCenter observer registered with no queue that runs its handler on the main actor
/// through ``MainDelivery`` and removes itself when released.
///
/// Use it for notifications that may be posted on any thread, where the poster must not wait for
/// main (a view's `NSView.frameDidChangeNotification`). It is not `MainActorObservation` on purpose:
/// that one registers on `queue: .main`, and NotificationCenter then makes a post from another thread
/// block that thread until main has run the handler. Here a post on the main thread runs the handler
/// inline, before `post` returns (the order of main-thread side effects is unchanged), and a post from
/// any other thread hands the handler to the main queue without waiting.
///
/// The owner's `deinit` needs nothing: `NotificationCenter.removeObserver(_:)` is thread-safe, so the
/// token's own deinit runs on any thread. Keep the token in a stored property; release it or call
/// ``cancel()`` to stop.
///
/// ```swift
/// view.postsFrameChangedNotifications = true
/// observation = MainDeliveryObservation(NSView.frameDidChangeNotification, object: view) { [weak self] in
///     self?.update()
/// }
/// ```
public final class MainDeliveryObservation {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    /// Observes `name` from `object` (nil: any sender) on `center` with no queue, delivering on the main actor.
    ///
    /// - Parameters:
    ///   - name: The notification to observe.
    ///   - object: Only notifications this object posts; nil for every sender.
    ///   - center: The center to observe (default `NotificationCenter.default`; tests pass their own).
    ///   - handler: Main-actor work for each notification. It gets no `Notification` (that is not
    ///     `Sendable` and may cross threads here); read what you need from the poster's state.
    public init(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        center: NotificationCenter = .default,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: nil) { _ in
            MainDelivery().run(handler)
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
