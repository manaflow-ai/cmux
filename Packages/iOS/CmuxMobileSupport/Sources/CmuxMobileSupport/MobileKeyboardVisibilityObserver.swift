#if canImport(UIKit)
import CmuxSafeConcurrency
import Observation
public import UIKit

/// Observable soft-keyboard visibility derived from UIKit's keyboard notifications.
///
/// Chrome that reflects the real keyboard state (rather than one responder's
/// focus intent) binds to `isVisible`: the keyboard can be raised by any
/// responder — an address field, a dialog's text field, or a hidden input
/// proxy — and per-responder focus flags go stale for every raiser but their own.
@MainActor
@Observable
public final class MobileKeyboardVisibilityObserver {
    /// Whether the soft keyboard is currently on screen.
    public private(set) var isVisible = false

    /// The observer tokens, removed in the nonisolated `deinit`. Written in
    /// `init`; a `Mutex` makes them reachable from `deinit` on any thread.
    // carve-out: never contended (init writes, deinit reads), it only makes the tokens Sendable.
    @ObservationIgnored
    private nonisolated let tokens = Mutex<[any NSObjectProtocol]>([])
    @ObservationIgnored
    private nonisolated let notificationCenter: NotificationCenter

    /// Creates an observer subscribed to the keyboard show/hide notifications.
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        observe(UIResponder.keyboardWillShowNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = true } // main-proof: observer on queue: .main
        }
        observe(UIResponder.keyboardWillHideNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = false } // main-proof: observer on queue: .main
        }
    }

    /// Observes `name` on the main queue. The token is made inside the lock,
    /// so it never belongs to the main actor and `deinit` can remove it.
    private nonisolated func observe(
        _ name: Notification.Name,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        let notificationCenter = notificationCenter
        tokens.withLock { tokens in
            tokens.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main, using: handler))
        }
    }

    deinit {
        let notificationCenter = notificationCenter
        tokens.withLock { tokens in
            for token in tokens {
                notificationCenter.removeObserver(token)
            }
        }
    }
}
#endif
