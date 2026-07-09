import Foundation

/// The menu-bar notifications-popover seam: the package decides the *sequence*
/// (surface a main window, then present the popover) and the app target performs
/// the AppKit side effects. The window resolve-or-create, `setActiveMainWindow`,
/// `bringToFront`, the `NSPopover` anchoring, and the delayed present all reach
/// late-bound `NSWindow`/`NSApp` state and the app-side titlebar accessory
/// controller, so they stay app-side behind this seam, keeping the package free
/// of AppKit.
///
/// The two methods correspond to the two phases of the legacy
/// `AppDelegate.showNotificationsPopoverFromMenuBar()`: first resolve the target
/// window (preferring the key window's main-terminal context, falling back to
/// the first registered main window, and creating one when none exists) and
/// bring it to front; then present the notifications popover. Splitting the
/// phases lets the coordinator own the ordering while the AppKit mechanics
/// (including the legacy post-bring-to-front present delay) stay app-side.
@MainActor
public protocol NotificationPopoverPresenting: AnyObject {
    /// Surfaces the main window that should host the menu-bar notifications
    /// popover, creating one when none is registered, and brings it to front.
    /// Mirrors the window-resolution and `setActiveMainWindow`/`bringToFront`
    /// phase of `AppDelegate.showNotificationsPopoverFromMenuBar()`.
    func surfaceWindowForMenuBarNotificationsPopover()

    /// Presents the notifications popover from the menu bar. Mirrors the final
    /// (delayed, non-animated) `showNotificationsPopover` phase of
    /// `AppDelegate.showNotificationsPopoverFromMenuBar()`.
    func presentMenuBarNotificationsPopover()
}
