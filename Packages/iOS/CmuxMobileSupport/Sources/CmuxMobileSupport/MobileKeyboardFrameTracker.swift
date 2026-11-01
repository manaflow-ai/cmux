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
    /// Whether the latest end frame puts the keyboard on screen. A hidden
    /// keyboard's frame starts where a shown one ends (the screen's bottom
    /// edge, in whatever coordinates UIKit posted), so this holds even when
    /// the frames are in another screen's points (an iPhone app on an iPad).
    public private(set) var isShown = false
    /// The bottom edge of the latest on-screen frame.
    private var shownBottom: CGFloat?

    /// Which keyboard notification a subscriber hears.
    public enum Change: Sendable {
        case willChangeFrame, didChangeFrame
    }

    private var subscribers: [(owner: () -> AnyObject?, handler: @MainActor (CGRect, Change) -> Void)] = []

    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
    private nonisolated let notificationCenter: NotificationCenter

    /// Creates a tracker subscribed to the keyboard frame notifications.
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        // will + did both update the record: `will` keeps an attach that lands
        // mid-transition current, `did` corrects a transition UIKit retargeted
        // after the `will` payload was posted.
        let changes: [(Notification.Name, Change)] = [
            (UIResponder.keyboardWillChangeFrameNotification, .willChangeFrame),
            (UIResponder.keyboardDidChangeFrameNotification, .didChangeFrame),
        ]
        tokens = changes.map { name, change in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let endFrame =
                    notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    self?.record(change: change, endFrame: endFrame)
                }
            }
        }
    }

    /// Calls `handler` with the end frame of every keyboard notification after
    /// this tracker has recorded it, inside UIKit's posting (and so the
    /// keyboard's animation: `UIView.inheritedAnimationDuration` is live),
    /// for as long as `owner` lives.
    public func subscribe(_ owner: AnyObject, handler: @escaping @MainActor (CGRect, Change) -> Void) {
        subscribers.append((owner: { [weak owner] in owner }, handler: handler))
    }

    private func record(change: Change, endFrame: CGRect?) {
        if let endFrame {
            lastEndFrame = endFrame
            isShown = endFrame.height > 0 && endFrame.minY < (shownBottom ?? .greatestFiniteMagnitude) - 0.5
            if isShown { shownBottom = endFrame.maxY }
        }
        guard let endFrame else { return }
        subscribers.removeAll { $0.owner() == nil }
        for subscriber in subscribers { subscriber.handler(endFrame, change) }
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
