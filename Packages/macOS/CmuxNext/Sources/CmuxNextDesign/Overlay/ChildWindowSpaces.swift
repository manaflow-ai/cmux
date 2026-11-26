public import AppKit
import CmuxNextCompat

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
/// `willEnterFullScreen` (before AppKit moves the window to its new Space) until `didExitFullScreen` or
/// `didFailToEnterFullScreen`. A child that never declared it is left alone: Chromium page windows go with their
/// window into its own full screen Space as any child does. The main window calls ``adopt(_:parent:)`` from its
/// `addChildWindow(_:ordered:)` override; the first adopt follows that window's transitions until it closes.
@MainActor
public struct ChildWindowSpaces {
    public init() {}
    /// Child windows that declared `.fullScreenAuxiliary` when they first came under a window.
    private static let auxiliaries = NSHashTable<NSWindow>.weakObjects()
    /// Windows between `willEnterFullScreen` and its end, or `willExitFullScreen` and its end.
    private static let transitioning = NSHashTable<NSWindow>.weakObjects()
    private static var observations: [ObjectIdentifier: [MainActorObservation]] = [:]

    /// Whether `window` is in full screen, entering it or leaving it (the style mask loses `.fullScreen` as the exit begins).
    public static func isInFullScreen(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.fullScreen) || transitioning.contains(window)
    }

    /// Whether `child` declared `.fullScreenAuxiliary` (it carries it only while its window is in full screen).
    public static func isAuxiliary(_ child: NSWindow) -> Bool { auxiliaries.contains(child) }

    /// Gives `child`, being added as a child window of `parent`, its parent's full screen membership.
    public static func adopt(_ child: NSWindow, parent: NSWindow) {
        guard !WindowOverlayHost.isAppKitChrome(child) else { return }
        follow(parent)
        if child.collectionBehavior.contains(.fullScreenAuxiliary) { auxiliaries.add(child) }
        guard auxiliaries.contains(child) else { return }
        setAuxiliary(child, isInFullScreen(parent))
    }

    /// Follows `window`'s full screen transitions for its child windows until it closes; once per window.
    static func follow(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard observations[id] == nil else { return }
        // Delivered in AppKit's own post (`atOnce`): the children carry the behavior before AppKit moves the window.
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (NSWindow) -> Void) -> MainActorObservation {
            MainActorObservation(name, object: window, atOnce: true, read: { $0.object as? NSWindow }) { posted in
                if let posted { body(posted) }
            }
        }
        observations[id] = [
            on(NSWindow.willEnterFullScreenNotification) { transitioning.add($0); sync($0) },
            on(NSWindow.didEnterFullScreenNotification) { transitioning.remove($0); sync($0) },
            on(NSWindow.didFailToEnterFullScreenNotification) { transitioning.remove($0); sync($0) },
            on(NSWindow.willExitFullScreenNotification) { transitioning.add($0); sync($0) },
            on(NSWindow.didExitFullScreenNotification) { transitioning.remove($0); sync($0) },
            on(NSWindow.didFailToExitFullScreenNotification) { transitioning.remove($0); sync($0) },
            on(NSWindow.willCloseNotification) { stopFollowing($0) },
        ]
    }

    /// Stops following `window` (it closed).
    static func stopFollowing(_ window: NSWindow) {
        observations.removeValue(forKey: ObjectIdentifier(window))?.forEach { $0.cancel() }
        transitioning.remove(window)
    }

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
