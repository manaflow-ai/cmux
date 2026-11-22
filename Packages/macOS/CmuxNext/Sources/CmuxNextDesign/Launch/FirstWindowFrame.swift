public import AppKit

/// The first window ordered in at launch draws and commits its first frame at once, from the
/// app's `WindowManager.makeController` right after `onFirstWindow` set that frame's completion
/// (`first_window_frame_committed`). It shows what the window already holds: the launch snapshot's
/// workspace (`LaunchSnapshotWindow`, the saved layout), else the connecting state.
///
/// Left to AppKit, the frame commits at the main thread's first idle run loop turn, and on a warm
/// relaunch that turn came only after the daemon's first tree was applied (`window.restore_wait`,
/// ~140 ms of the ~145 ms from `window.ordered_front` to the frame). The tree then applies into the
/// window on screen in place, as `WindowManager.restore` adopts the launch window.
@MainActor
public enum FirstWindowFrame {
    /// Lays out, draws and commits `window`'s frame now, when it is on screen (the app calls it
    /// for the launch window only, before the restore); `mark` gets `first_window_flushed` (the
    /// app's `DebugTimings.markLaunch`).
    public static func commit(_ window: NSWindow?, mark: (String) -> Void) {
        guard let window, window.isVisible else { return }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        // perf-gate-ok: once per launch, the first window's first frame; waiting for the run loop's commit waited for the daemon's first tree
        CATransaction.flush()
        mark("first_window_flushed")
    }
}
