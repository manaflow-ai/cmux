#if canImport(UIKit)
public import SwiftUI
public import UIKit

/// App-lifetime record of the software keyboard's most recent end frame.
///
/// UIKit posts keyboard frame notifications regardless of which views are
/// installed in a window, but a view-attached `keyboardWillChangeFrame`
/// handler misses every transition that happens while its view is detached
/// (for example across a workspace switch). A host that reads this tracker on
/// window attach can seat its dock at the real keyboard edge instead of the
/// stale pre-detach state. The composition root owns the app-wide instance
/// and injects it through ``EnvironmentValues/mobileKeyboardFrameTracker`` so
/// its record spans host view lifetimes.
///
/// The recorded frame is screen-space, exactly as UIKit broadcasts it to
/// every scene in the process. Consumers convert it through their OWN window
/// and intersect it with their own bounds (``MobileKeyboardReservation``), so
/// a multi-scene iPad read yields the overlap the keyboard actually has over
/// that scene's window; a scene the keyboard does not cover resolves to zero
/// reservation. A per-scene visibility difference observed while a host was
/// detached self-corrects on the next keyboard notification in that scene,
/// the same convergence UIKit's own process-wide broadcast relies on.
@MainActor
public final class MobileKeyboardFrameTracker {
    /// The keyboard's most recent end frame in screen coordinates, or `nil`
    /// before the first keyboard notification observed by this instance.
    public private(set) var lastEndFrame: CGRect?

    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
    private nonisolated let notificationCenter: NotificationCenter

    /// Creates a tracker subscribed to the keyboard frame notifications.
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        // will + did both update the record: `will` keeps an attach that lands
        // mid-transition current, `did` corrects a transition UIKit retargeted
        // after the `will` payload was posted.
        tokens = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ].map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let endFrame =
                    notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                guard let endFrame else { return }
                MainActor.assumeIsolated { self?.lastEndFrame = endFrame }
            }
        }
    }

    deinit {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }

    /// The keyboard's current bottom overlap of `view`, or `nil` when no
    /// keyboard notification has been observed yet. Floating and split iPad
    /// keyboards resolve to zero overlap through the shared reservation math.
    public func currentOverlap(in view: UIView) -> CGFloat? {
        guard let lastEndFrame, let window = view.window else { return nil }
        let keyboardFrameInWindow = window.convert(lastEndFrame, from: nil)
        let viewFrameInWindow = view.convert(view.bounds, to: window)
        return MobileKeyboardReservation(
            keyboardFrameInWindow: keyboardFrameInWindow,
            viewFrameInWindow: viewFrameInWindow
        ).height
    }

    /// Whether the keyboard is currently visible to `view`, or `nil` when no
    /// keyboard notification has been observed yet.
    public func currentVisibility(in view: UIView) -> Bool? {
        guard let lastEndFrame, let window = view.window else { return nil }
        let keyboardFrameInWindow = window.convert(lastEndFrame, from: nil)
        let viewFrameInWindow = view.convert(view.bounds, to: window)
        return MobileKeyboardVisibility(
            keyboardFrameInWindow: keyboardFrameInWindow,
            viewFrameInWindow: viewFrameInWindow
        ).isVisible
    }
}

extension EnvironmentValues {
    /// The composition-root-owned keyboard frame tracker, `nil` when the app
    /// shell has not injected one (previews, isolated harnesses).
    @Entry public var mobileKeyboardFrameTracker: MobileKeyboardFrameTracker? = nil
}
#endif
