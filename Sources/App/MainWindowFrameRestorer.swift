import AppKit

/// Restores a ``CmuxMainWindow`` to the size the user last left it at when the
/// system shrinks it in the background — a native-fullscreen exit, an un-zoom
/// revert, or a display-mode resize around a display sleep/wake (issue #5492).
///
/// ``CmuxMainWindow/constrainFrameRect(_:to:)`` (#6305) already vetoes AppKit's
/// re-constrain of an on-screen frame, but it cannot undo a *real* resize
/// applied through another path while cmux is in the background. This restorer
/// captures each main window's frame as the app resigns active and, on the next
/// activation, restores any window that shrank — but only when a real display
/// transition (display/system sleep, or a screen-parameter change) was observed
/// while the app was inactive, so a deliberate background resize by a window
/// manager, AppleScript, or macOS window management is left untouched.
///
/// Pure state + decisions so it stays unit-testable; ``AppDelegate`` owns the
/// app-active and display notifications and forwards into it.
@MainActor
final class MainWindowFrameRestorer {
    private var framesBeforeDeactivation: [ObjectIdentifier: NSRect] = [:]
    private var sawDisplayTransitionWhileInactive = false

    /// Snapshot every `CmuxMainWindow` frame as the app resigns active. Resets
    /// the display-transition flag so each inactive period is judged on its own.
    func captureFrames(of windows: [NSWindow]) {
        framesBeforeDeactivation.removeAll(keepingCapacity: true)
        for window in windows where window is CmuxMainWindow {
            framesBeforeDeactivation[ObjectIdentifier(window)] = window.frame
        }
        sawDisplayTransitionWhileInactive = false
    }

    /// Record a display/system sleep or screen-parameter change. Only counts
    /// while the app is inactive, and arming on the sleep side sets the flag
    /// while the user is still away — important on laptops where the display
    /// wakes at the same instant the user returns and a wake-armed flag could
    /// land after the activation check.
    func noteDisplayTransition(appIsActive: Bool) {
        guard !appIsActive else { return }
        sawDisplayTransitionWhileInactive = true
    }

    /// On activation, restore any captured window that shrank to a
    /// still-reachable earlier frame, but only if a display transition was seen
    /// while inactive. One-shot: captured frames and the flag are cleared after.
    func restoreIfNeeded(windows: [NSWindow], visibleFrames: [NSRect]) {
        defer {
            framesBeforeDeactivation.removeAll(keepingCapacity: true)
            sawDisplayTransitionWhileInactive = false
        }
        guard sawDisplayTransitionWhileInactive,
              !framesBeforeDeactivation.isEmpty else { return }
        for window in windows where window is CmuxMainWindow {
            guard let previous = framesBeforeDeactivation[ObjectIdentifier(window)] else { continue }
            CmuxMainWindow.applyRestoredFrameAfterInactiveDisplayTransition(
                to: window,
                frameBeforeDeactivation: previous,
                visibleFrames: visibleFrames
            )
        }
    }
}
