import AppKit

/// A main window's child panels join a full screen Space only with their own window.
///
/// Empty cmux window over a full screen transition (user, 2026-11-25): the child panels of a main window (the overlay
/// host panel, the divider catchers, hover cards, the palette, popups) declare `.fullScreenAuxiliary` ("can be shown on
/// the same Space as a full screen window"). AppKit keeps a child window on its parent's Space, so a background cmux
/// window whose group took such a panel while ANOTHER app's full screen Space was the current one on its display went
/// into that Space with it. Parked in a full screen Space it does not own, the window drew over every later full screen
/// enter and exit on that display, about 0.6 s each (bg-policy's ShellWindow 54552 in Chrome's full screen Space, its
/// overlay panel still there, 2026-11-26).
///
/// A child panel cmux makes and marks (``FullScreenFollowingChild``) that declares `.fullScreenAuxiliary` keeps it only
/// while its window is in full screen: from the window's `willEnterFullScreen` (before AppKit moves it to its new Space)
/// until its `didExitFullScreen`, or a failed enter. Every other child keeps its own collection behavior: a Chromium page
/// window keeps what Chromium gave it, as it does for Mission Control (`MissionControlPageWindowTests`, cmux#48535), and
/// so do Chromium's own panels and AppKit's full screen titlebar. The main window's `addChildWindow(_:ordered:)` override
/// adopts each child (``ChildWindowPolicy/admit(_:parent:)``); the app's full screen transition tracker, which observes
/// every window's transitions once for the app (`LiveResizeWindows`), owns this and tells it each change.
@MainActor
final class ChildWindowSpaces {
    /// Marked child panels that declared `.fullScreenAuxiliary` when they came under a main window.
    private let declared = NSHashTable<NSWindow>.weakObjects()

    /// `child` comes under `parent`, before AppKit attaches it: a marked child that declared the behavior carries it only
    /// while `parent` is in full screen (`inFullScreen`: in it, entering it or leaving it). Other children are left alone.
    func adopt(_ child: NSWindow, inFullScreen: Bool) {
        guard child is any FullScreenFollowingChild else { return }
        if child.collectionBehavior.contains(.fullScreenAuxiliary) { declared.add(child) }
        if declared.contains(child) { setAuxiliary(child, inFullScreen) }
    }

    /// `window` entered, left or stayed out of full screen: each of its declared children follows.
    func window(_ window: NSWindow, isInFullScreen inFullScreen: Bool) {
        for child in window.childWindows ?? [] where declared.contains(child) { setAuxiliary(child, inFullScreen) }
    }

    private func setAuxiliary(_ child: NSWindow, _ on: Bool) {
        let behavior = child.collectionBehavior
        guard behavior.contains(.fullScreenAuxiliary) != on else { return }
        child.collectionBehavior = on ? behavior.union(.fullScreenAuxiliary) : behavior.subtracting(.fullScreenAuxiliary)
    }
}
