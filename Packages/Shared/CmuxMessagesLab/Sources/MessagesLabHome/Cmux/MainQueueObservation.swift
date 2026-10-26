// cmux (p10-stability-044): the pane's window notifications as main-actor work. Not a vendored file.
import Foundation

/// A NotificationCenter observer whose handler runs on the main actor and that stops when it is released.
///
/// The pane's form of CmuxNextCompat's `MainActorObservation` (this package cannot import CmuxNext): the
/// main-delivery proof is here once, and an owner keeps the observation in a stored property instead of a
/// token it must remove in its `deinit` (a main-actor class's `deinit` is nonisolated, and the token is not
/// `Sendable`). `NotificationCenter.removeObserver(_:)` is thread-safe, so this `deinit` needs no isolation.
final class MainQueueObservation {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    /// Observes `name` from `object` on `center`, delivering on the main queue.
    /// - Parameters:
    ///   - name: The notification to observe.
    ///   - object: Only notifications this object posts; nil for every sender.
    ///   - center: The center to observe (tests pass their own).
    ///   - handler: Main-actor work for each notification (read the poster's state, not the payload).
    init(_ name: Notification.Name, object: AnyObject?, center: NotificationCenter = .default,
         _ handler: @escaping @MainActor @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            // main-proof: the observer is registered on the main queue (queue: .main).
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit { center.removeObserver(token) }
}
