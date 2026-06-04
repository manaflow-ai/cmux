import Foundation

/// Owns a single block-based `NotificationCenter` observer registration and
/// removes it on `deinit`.
///
/// Storing one of these instead of the raw observer token lets an `actor`
/// register an observer without ever touching the non-`Sendable` token from its
/// own `nonisolated deinit`: when the owning actor is deallocated, ARC releases
/// the handle and the handle's `deinit` removes the observer. The block is the
/// only `NotificationCenter` surface the store exposes — the leak-prone
/// `NotificationCenter.notifications(named:)` async iterator (#5329 / #5309) is
/// never used.
final class NotificationObserverHandle {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    /// Registers `block` for `name` on `center` (any object, no specific queue).
    /// - Parameters:
    ///   - center: The center to observe. Defaults to `.default`.
    ///   - name: The notification name to observe.
    ///   - block: Invoked for each matching notification. Must be `@Sendable`
    ///     because `NotificationCenter` may deliver on any thread.
    init(
        center: NotificationCenter = .default,
        name: Notification.Name,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        self.center = center
        self.token = center.addObserver(forName: name, object: nil, queue: nil, using: block)
    }

    deinit {
        center.removeObserver(token)
    }
}
