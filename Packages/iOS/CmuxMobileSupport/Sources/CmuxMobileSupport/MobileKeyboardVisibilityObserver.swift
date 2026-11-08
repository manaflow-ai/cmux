#if canImport(UIKit)
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

    @ObservationIgnored
    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
    @ObservationIgnored
    private nonisolated let notificationCenter: NotificationCenter

    /// Creates an observer subscribed to the keyboard show/hide notifications.
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        tokens = [
            notificationCenter.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isVisible = true }
            },
            notificationCenter.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isVisible = false }
            },
        ]
    }

    deinit {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }
}
#endif
