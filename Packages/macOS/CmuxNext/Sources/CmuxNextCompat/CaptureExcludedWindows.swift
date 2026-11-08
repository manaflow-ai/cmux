public import AppKit

/// SECURITY: the app's windows that cmux's own screen captures leave out (screen sharing, `cmux rd serve`,
/// its screen recorders): every window of the app with `NSWindow.sharingType = .none`, such as the join
/// consent ask or a revealed password. That property only asks captures to skip a window: since macOS
/// 15.4 a ScreenCaptureKit capture may still show it, and another app's capture is not ours to control.
/// So every capture cmux makes reads this list and leaves these windows out by id.
///
/// The list is read from the windows themselves, never kept: a window is on it from the moment it has a
/// number (it first ordered in) and sets `.none`. Whoever shows such a window, or changes a window's
/// sharing, calls ``changed()`` so a running capture follows at once.
public enum CaptureExcludedWindows {
    /// Posted on the main thread by ``changed()``.
    public static let didChange = Notification.Name("cmux.captureExcludedWindows.didChange")

    /// The windows to leave out now (window numbers, ScreenCaptureKit's `windowID`).
    @MainActor public static var windowIDs: Set<CGWindowID> {
        Set((NSApp?.windows ?? []).lazy.filter { $0.sharingType == .none && $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
    }

    /// A window that leaves captures showed, or a window's sharing changed: running captures read the list again.
    @MainActor public static func changed() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Calls `changed` with the new list inside every ``changed()`` (on the main thread, before it returns),
    /// until the returned token is released.
    public static func observe(_ changed: @escaping @MainActor @Sendable (Set<CGWindowID>) -> Void) -> Observation {
        // No queue: the center calls this on the poster's thread, the main one (``changed()`` is main-actor).
        Observation(NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { changed(windowIDs) }
        })
    }

    /// Ends an ``observe(_:)`` when released.
    public final class Observation: Sendable {
        // The center's token: only handed back to the center, which takes it from any thread.
        private nonisolated(unsafe) let token: any NSObjectProtocol

        init(_ token: any NSObjectProtocol) {
            self.token = token
        }

        deinit { NotificationCenter.default.removeObserver(token) }
    }
}
