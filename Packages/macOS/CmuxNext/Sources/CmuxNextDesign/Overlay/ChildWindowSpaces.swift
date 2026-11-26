public import AppKit

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
/// A child that declares `.fullScreenAuxiliary` keeps it only while its window is in full screen: from
/// `windowWillEnterFullScreen` (before AppKit moves the window to its new Space) until `windowDidExitFullScreen` or
/// `windowDidFailToEnterFullScreen`. A child that never declared it is left alone: Chromium page windows go with their
/// window into its own full screen Space as any child does. The main window calls ``adopt(_:parent:)`` from its
/// `addChildWindow(_:ordered:)` override, and its delegate reports the transitions (AppKit posts no notification for a
/// failed one).
@MainActor
public struct ChildWindowSpaces {
    public init() {}
    /// Child windows that declared `.fullScreenAuxiliary` when they first came under a window.
    private static let auxiliaries = NSHashTable<NSWindow>.weakObjects()
    /// Windows entering or leaving full screen (the style mask loses `.fullScreen` as the exit begins).
    private static let transitioning = NSHashTable<NSWindow>.weakObjects()

    /// Whether `window` is in full screen, entering it or leaving it.
    public static func isInFullScreen(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.fullScreen) || transitioning.contains(window)
    }

    /// Whether `child` declared `.fullScreenAuxiliary` (it carries it only while its window is in full screen).
    public static func isAuxiliary(_ child: NSWindow) -> Bool { auxiliaries.contains(child) }

    /// Gives `child`, being added as a child window of `parent`, its parent's full screen membership.
    public static func adopt(_ child: NSWindow, parent: NSWindow) {
        guard !WindowOverlayHost.isAppKitChrome(child) else { return }
        if child.collectionBehavior.contains(.fullScreenAuxiliary) { auxiliaries.add(child) }
        guard auxiliaries.contains(child) else { return }
        setAuxiliary(child, isInFullScreen(parent))
    }

    /// `windowWillEnterFullScreen`: the children may join the new full screen Space before AppKit moves the window.
    public static func willEnterFullScreen(_ window: NSWindow) { transitioning.add(window); sync(window) }
    /// `windowDidEnterFullScreen`: the style mask says full screen from now on.
    public static func didEnterFullScreen(_ window: NSWindow) { transitioning.remove(window); sync(window) }
    /// `windowDidFailToEnterFullScreen`: the window stays windowed.
    public static func didFailToEnterFullScreen(_ window: NSWindow) { transitioning.remove(window); sync(window) }
    /// `windowWillExitFullScreen`: the children stay with the window while it leaves.
    public static func willExitFullScreen(_ window: NSWindow) { transitioning.add(window); sync(window) }
    /// `windowDidExitFullScreen`: windowed again, the children can no longer join a full screen Space.
    public static func didExitFullScreen(_ window: NSWindow) { transitioning.remove(window); sync(window) }
    /// `windowDidFailToExitFullScreen`: the window stays in full screen, and its children with it.
    public static func didFailToExitFullScreen(_ window: NSWindow) { transitioning.remove(window) }

    /// Every declared child of `window` follows the window's full screen state.
    static func sync(_ window: NSWindow) {
        let inFullScreen = isInFullScreen(window)
        for child in window.childWindows ?? [] where auxiliaries.contains(child) { setAuxiliary(child, inFullScreen) }
    }

    private static func setAuxiliary(_ child: NSWindow, _ on: Bool) {
        let behavior = child.collectionBehavior
        guard behavior.contains(.fullScreenAuxiliary) != on else { return }
        child.collectionBehavior = on ? behavior.union(.fullScreenAuxiliary) : behavior.subtracting(.fullScreenAuxiliary)
    }
}
