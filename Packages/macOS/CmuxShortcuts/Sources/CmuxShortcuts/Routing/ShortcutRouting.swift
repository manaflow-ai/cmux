public import AppKit

/// The single entry point the app target's `NSApplication`/`NSWindow` swizzle
/// forwarders call to route a raw keyboard ``NSEvent`` through cmux's
/// configured-shortcut dispatch.
///
/// ## Why this seam exists
///
/// The configured-shortcut routing used to live as ~80 methods and a dozen
/// stored properties on the `AppDelegate` god object, on the per-keystroke hot
/// path. It is relocated into ``ShortcutRouter`` in this package. The app target
/// keeps only the AppKit-type entry points it cannot move (the
/// `NSApplication.cmux_sendEvent` / `NSWindow.cmux_performKeyEquivalent`
/// swizzles, which extend AppKit types and therefore cannot cross a module
/// boundary). Those forwarders pass the live `NSEvent` plus the live key window
/// straight down to ``handle(event:)``.
///
/// ## Latency contract
///
/// `cmux_sendEvent` is on the keystroke hot path, so the forward must be O(1):
/// the swizzle holds one stored reference to the conforming ``ShortcutRouter``
/// and calls ``handle(event:)`` with no allocation. All routing decisions
/// happen inside the router, which reads window/responder/focus state through
/// the ``ShortcutRoutingHost`` seam rather than allocating per event.
///
/// ## Isolation
///
/// `@MainActor` because every caller (the local key-event monitor, the menu
/// suppressor, the AppKit swizzles) already runs on the main thread, so routing
/// state co-locates with its callers and no cross-actor bridge appears on the
/// hot path (the same ruling as ``ShortcutCoordinator``).
@MainActor
public protocol ShortcutRouting: AnyObject {
    /// Routes `event` through cmux's configured-shortcut dispatch.
    ///
    /// - Returns: `true` when the shortcut routing consumed the event (the caller
    ///   must not propagate it further), `false` to let AppKit continue normal
    ///   delivery. Faithful relocation of the former
    ///   `AppDelegate.handleCustomShortcut(event:)` return contract.
    func handle(event: NSEvent) -> Bool

    /// Routes `event` through the browser-popup close-shortcut dispatch targeting
    /// `popupWindow`, applying the same keyDown/recorder/chord/focus-cache
    /// lifecycle as ``handle(event:)``. Called by the app target's
    /// `BrowserPopupWindowController.performKeyEquivalent` forwarder.
    ///
    /// - Returns: `true` when the popup close shortcut consumed the event.
    ///   Faithful relocation of the former
    ///   `AppDelegate.handleBrowserPopupCloseShortcutKeyEquivalent(event:popupWindow:)`
    ///   return contract.
    func handle(popupCloseEvent event: NSEvent, popupWindow: NSWindow) -> Bool
}
