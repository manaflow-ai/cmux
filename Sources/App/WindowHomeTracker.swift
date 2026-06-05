import AppKit
import Foundation

/// Tracks the user's intended "home" position for each main window so that a
/// window relocated off a display by macOS (display sleep, cable disconnect,
/// system sleep) can be restored to its original display + frame once that
/// display reappears.
///
/// macOS rescues windows off a vanishing display onto the remaining one but
/// never moves them back when the display returns. ``WindowHomeTracker`` records
/// the last *user-initiated* placement of each window; ``AppDelegate`` consults
/// it when the display configuration changes and re-applies the home frame once
/// the home display is connected again.
@MainActor
final class WindowHomeTracker {
    /// A window's remembered position: the frame it occupied and a snapshot of
    /// the display it occupied (display id + frame + visible frame).
    struct Home: Equatable {
        var frame: CGRect
        var display: SessionDisplaySnapshot
    }

    private var homesByWindowId: [UUID: Home] = [:]

    /// Records (or replaces) the home position for the given window.
    func recordHome(windowId: UUID, frame: CGRect, display: SessionDisplaySnapshot) {
        homesByWindowId[windowId] = Home(frame: frame, display: display)
    }

    /// Returns the remembered home for the given window, if any.
    func home(for windowId: UUID) -> Home? {
        homesByWindowId[windowId]
    }

    /// Forgets the home for the given window (e.g. when it closes).
    func clear(windowId: UUID) {
        homesByWindowId.removeValue(forKey: windowId)
    }

    /// Decides whether an observed window move/resize should be recorded as the
    /// new home.
    ///
    /// A move is treated as a genuine user placement — and therefore a home
    /// update — only when it was an interactive user drag/resize
    /// (`isUserInitiated`) and none of the suppressing conditions hold. The macOS
    /// rescue move that relocates a window off a vanishing display arrives
    /// *without* a preceding `windowWillMove`, so it reports `isUserInitiated ==
    /// false` and is excluded — this is what prevents the rescue from clobbering
    /// the remembered home. A real user drag happens with the window in a normal
    /// (non-fullscreen/zoomed/miniaturized) state on a connected display.
    ///
    /// - Parameters:
    ///   - isUserInitiated: The move/resize came from an interactive user drag.
    ///   - isReconciling: We are inside a programmatic display-change reconcile.
    ///   - isApplyingSessionRestore: Startup/session restore is in progress.
    ///   - isFullScreen: The window is in macOS full screen.
    ///   - isZoomed: The window is zoomed (green-button maximized).
    ///   - isMiniaturized: The window is minimized to the Dock.
    ///   - screenPresent: The window's current display is in the live screen list.
    /// - Returns: `true` when the move should update the recorded home.
    static func shouldRecordHome(
        isUserInitiated: Bool,
        isReconciling: Bool,
        isApplyingSessionRestore: Bool,
        isFullScreen: Bool,
        isZoomed: Bool,
        isMiniaturized: Bool,
        screenPresent: Bool
    ) -> Bool {
        isUserInitiated
            && !isReconciling
            && !isApplyingSessionRestore
            && !isFullScreen
            && !isZoomed
            && !isMiniaturized
            && screenPresent
    }
}
