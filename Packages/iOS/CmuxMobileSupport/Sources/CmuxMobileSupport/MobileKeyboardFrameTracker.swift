#if canImport(UIKit)
public import UIKit

/// Process-wide record of the software keyboard's most recent frame transition.
///
/// `UIView.keyboardLayoutGuide` only reflects keyboard changes UIKit routed to
/// that view's window while the view was installed; a view (re)attached around
/// a workspace switch can miss the transition entirely and stay seated on the
/// guide's bottom-safe-area fallback while the keyboard is up. Keyboard
/// notifications, by contrast, are posted process-wide regardless of any
/// view's attachment, so this tracker is always able to answer "where is the
/// keyboard now?" for late-attaching views. It is a read-only catch-up source:
/// guide-constrained chrome keeps following the guide, and consumers use the
/// tracker only to bound how far below the keyboard that chrome may sit.
@MainActor
public final class MobileKeyboardFrameTracker {
    /// The single process-wide tracker. Created on first access; access it
    /// before the first keyboard presentation so no transition is missed.
    /// The keyboard is process-global UIKit state, and a late-created view
    /// must read transitions observed BEFORE it existed — a per-instance
    /// observer cannot provide that by construction. Consumers hold an
    /// injectable reference (`GhosttySurfaceView.keyboardFrameTracker`), so
    /// tests isolate with a private-center instance and never touch this one.
    // lint:allow singleton — process-global keyboard state, injectable at use sites.
    public static let shared = MobileKeyboardFrameTracker()

    /// The most recent keyboard transition, or `nil` while the keyboard state
    /// is unknown (nothing observed yet, keyboard fully hidden, a transition
    /// posted without a readable end frame, or state discarded on
    /// backgrounding because iOS can tear the keyboard down without a paired
    /// notification).
    public private(set) var latestTransition: MobileKeyboardTransition?

    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
    private nonisolated let notificationCenter: NotificationCenter

    /// Creates a tracker subscribed to the keyboard frame notifications.
    ///
    /// - Parameter notificationCenter: The center to observe; tests inject a
    ///   private center so posted fixtures cannot leak into other suites.
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        tokens = [
            notificationCenter.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let transition = MobileKeyboardTransition(notification: notification)
                MainActor.assumeIsolated {
                    // A transition without a readable end frame leaves the
                    // keyboard state unknown; fail closed (clear) so a stale
                    // floor can never keep the dock and viewport raised after
                    // the keyboard actually changed.
                    self?.latestTransition = transition
                }
            },
            notificationCenter.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.latestTransition = nil }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.latestTransition = nil }
            },
        ]
    }

    deinit {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }

    /// Returns how much of `view` the tracked keyboard covers from its bottom
    /// edge, or zero while the keyboard state is unknown, the view is detached,
    /// or the keyboard does not reach the view's bottom (floating/split iPad
    /// keyboards, or an end frame parked below the screen after a dismissal).
    public func overlap(in view: UIView) -> CGFloat {
        latestTransition?.overlap(in: view) ?? 0
    }

    /// Returns whether the tracked keyboard is visible to `view` (including
    /// floating/split iPad keyboards that reserve no bottom space), or false
    /// while the keyboard state is unknown or the view is detached.
    public func isVisible(in view: UIView) -> Bool {
        latestTransition?.isVisible(in: view) ?? false
    }
}
#endif
