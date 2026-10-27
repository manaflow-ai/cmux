import AppKit
import CmuxNextWakeups

/// Repaints a view when its window becomes or resigns key, so a keyboard-focus
/// tint or ring shows only in the key window, as AppKit's focus ring did
/// (cx-wqn5). It subscribes to the window's one fan-out of each notice
/// (``WindowEvents``), not to NotificationCenter per view. No node: the repaint
/// is a dirty flag, and AppKit draws a hidden view only when it shows.
@MainActor
final class KeyWindowRepaint {
    private weak var view: NSView?
    private var subscriptions: [EventSubscription] = []

    init(_ view: NSView) {
        self.view = view
    }

    /// Whether a view with keyboard focus shows it: its window is key (or it
    /// has no window yet, which draws nothing).
    static func showsFocus(_ view: NSView, focused: Bool) -> Bool {
        focused && (view.window?.isKeyWindow ?? true)
    }

    /// Call from the view's `viewDidMoveToWindow()`.
    func track() {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        guard let window = view?.window else { return }
        let events = WindowEvents.of(window)
        let repaint: @MainActor () -> Void = { [weak self] in self?.view?.needsDisplay = true }
        subscriptions = [
            events.subscribe(NSWindow.didBecomeKeyNotification, owner: "Sidebar.keyWindowRepaint", repaint),
            events.subscribe(NSWindow.didResignKeyNotification, owner: "Sidebar.keyWindowRepaint", repaint),
        ]
    }
}
