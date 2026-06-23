public import AppKit

/// The read/route seam through which ``ShortcutRouter`` reaches the app's live
/// window state without owning it.
///
/// ## Why this seam exists
///
/// Shortcut routing must answer "which window is this keystroke for" and "make
/// that window's terminal context active" before it can dispatch. Those
/// decisions read the key window, the main window, the per-event window, and the
/// registry of main terminal windows, all of which are owned by the app target's
/// window-lifecycle slice (`AppDelegate` plus `CmuxWindowing`). The router
/// depends on this protocol, not on those god types, so the keystroke hot path
/// takes one held reference and the window slice can move independently.
///
/// The conformer is the app target's window-routing owner; it forwards each
/// member to the existing `shortcutRoutingKeyWindow` / `shortcutRoutingActiveWindow`
/// / `preferredMainWindowContextForShortcutRouting` machinery while that
/// machinery itself remains app-side (it mutates `AppDelegate`'s own
/// `tabManager`/`sidebarState` stored properties, which cannot cross a module
/// boundary).
@MainActor
public protocol ShortcutWindowRouting: AnyObject {
    /// The window the active keystroke should route to for shortcut purposes,
    /// resolved with the app's full key/main/event/registry fallback chain.
    /// Faithful relocation of `AppDelegate.shortcutRoutingKeyWindow`.
    var shortcutRoutingKeyWindow: NSWindow? { get }

    /// The window a window-scoped shortcut action (split, group) should act on,
    /// preferring the key window and falling back to the active main window.
    /// Faithful relocation of `AppDelegate.shortcutRoutingActiveWindow`.
    var shortcutRoutingActiveWindow: NSWindow? { get }

    /// The `windowNumber` shortcut chord arming should scope a prefix to for
    /// `event`, or `nil` when no addressable window resolves. Faithful
    /// relocation of `AppDelegate.configuredShortcutChordWindowNumber(for:)`.
    func chordWindowNumber(for event: NSEvent) -> Int?

    /// Synchronizes the app's active main-window context (tab manager, sidebar,
    /// file explorer) to the window `event` routes to, returning `false` when no
    /// context resolves. Faithful relocation of
    /// `AppDelegate.synchronizeShortcutRoutingContext(event:)`; the body stays
    /// app-side because it mutates `AppDelegate`'s own stored window state.
    @discardableResult
    func synchronizeRoutingContext(for event: NSEvent) -> Bool
}
