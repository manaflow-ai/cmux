public import AppKit

/// Repaints a view when its window becomes or resigns key, so a keyboard-focus
/// tint or ring shows only in the key window, as AppKit's focus ring did
/// (cx-wqn5), and an app scene's progress bar fills grey in a window that is not key. Block observers on `queue: .main` (see `PointerHover`'s
/// `KeyWindowObserver`, #18771).
@MainActor
public final class KeyWindowRepaint {
    private weak var view: NSView?
    private var tokens: [any NSObjectProtocol] = []

    /// Creates the repaint for `view`; it observes nothing until ``track()``.
    /// - Parameter view: The view to mark for display; held weakly.
    public init(_ view: NSView) {
        self.view = view
    }

    /// Whether a view with keyboard focus shows it: its window is key (or it
    /// has no window yet, which draws nothing).
    /// - Parameters:
    ///   - view: The focused view.
    ///   - focused: Whether it has keyboard focus.
    /// - Returns: Whether to draw its focus.
    public static func showsFocus(_ view: NSView, focused: Bool) -> Bool {
        focused && (view.window?.isKeyWindow ?? true)
    }

    /// Call from the view's `viewDidMoveToWindow()`.
    public func track() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
        guard let window = view?.window else { return }
        tokens = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                // main-proof: the observer runs on the main queue (queue: .main)
                MainActor.assumeIsolated { self?.view?.needsDisplay = true }
            }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }
}
