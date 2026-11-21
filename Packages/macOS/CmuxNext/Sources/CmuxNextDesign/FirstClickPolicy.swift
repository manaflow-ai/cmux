public import AppKit

/// Whether a press in a window that is not key acts at once, instead of only making the window key.
///
/// AppKit gives a press in a window that is not key to the view under it only when that view
/// answers `acceptsFirstMouse(for:)` with `true`; otherwise the press only makes the window key and
/// the person has to press again (user 2026-10-30: "a lot of buttons, i feel like i have to click
/// twice for it to actually work"). That rule is for a window behind another app's windows: the
/// first click there brings it forward. cmux's own windows hold the key while the person works in
/// cmux, too: a Chromium page is a child window that takes the key (Home, the agent chat, New Tab and
/// every browser tab), and so do the palette and the floating panels. After a click in a page, every
/// native control of the window that holds the page (titlebar, sidebar, tab bar, toolbar, Settings
/// rows, dialogs) then needed two clicks, unless that one view said yes itself (77 overrides did).
///
/// The rule here is the window's, so it covers every view, native or SwiftUI, with no per-view
/// override. A press acts at once when the app is active, no sheet or modal session is up, and the
/// key window is this window's own child window (any depth: a Chromium page, a popover), or one of
/// the app's free panels or no window while this window is the main window (or there is none). A
/// press in a window behind another app, or behind another of cmux's own main windows, keeps
/// AppKit's rule: the first click only brings that window forward.
///
/// ```swift
/// override func sendEvent(_ event: NSEvent) {
///     if FirstClickPolicy().takesFirstClick(event, in: self, keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow,
///                                           appIsActive: NSApp.isActive, appIsModal: NSApp.modalWindow != nil) {
///         makeKey()
///     }
///     super.sendEvent(event)
/// }
/// ```
@MainActor
public struct FirstClickPolicy {
    /// Makes the policy; it holds no state.
    public init() {}

    /// Whether `event`, a press AppKit is about to give `window`, should act at once.
    ///
    /// - Parameter event: The event `window.sendEvent(_:)` got.
    /// - Parameter window: The window the event is for.
    /// - Parameter keyWindow: The app's key window (`NSApp.keyWindow`).
    /// - Parameter mainWindow: The app's main window (`NSApp.mainWindow`).
    /// - Parameter appIsActive: Whether the app is the active app (`NSApp.isActive`).
    /// - Parameter appIsModal: Whether a modal session runs (`NSApp.modalWindow != nil`).
    /// - Returns: `true` when the caller should make `window` key before it sends the event on, so
    ///   AppKit delivers the press to the view under it as a normal click.
    public func takesFirstClick(_ event: NSEvent, in window: NSWindow, keyWindow: NSWindow?, mainWindow: NSWindow?,
                                appIsActive: Bool, appIsModal: Bool) -> Bool {
        takesFirstClick(type: event.type, modifiers: event.modifierFlags, in: window, keyWindow: keyWindow, mainWindow: mainWindow,
                        appIsActive: appIsActive, appIsModal: appIsModal)
    }

    /// ``takesFirstClick(_:in:keyWindow:mainWindow:appIsActive:appIsModal:)`` for an event's type and modifiers.
    ///
    /// - Parameter type: The event's type; only mouse-downs qualify.
    /// - Parameter modifiers: The event's modifiers. A Command-press acts at once only while this
    ///   window's own child holds the key; elsewhere it keeps AppKit's rule (it acts in a background
    ///   window without bringing it forward).
    /// - Parameter window: The window the event is for.
    /// - Parameter keyWindow: The app's key window.
    /// - Parameter mainWindow: The app's main window.
    /// - Parameter appIsActive: Whether the app is the active app.
    /// - Parameter appIsModal: Whether a modal session runs.
    /// - Returns: Whether the press should act at once.
    public func takesFirstClick(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, in window: NSWindow,
                                keyWindow: NSWindow?, mainWindow: NSWindow?, appIsActive: Bool, appIsModal: Bool) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: break
        default: return false
        }
        // A sheet or a modal session keeps the keys where AppKit put them (a Save panel's name field).
        guard appIsActive, !appIsModal, !window.isKeyWindow, window.canBecomeKey, window.attachedSheet == nil,
              keyWindow?.sheetParent == nil else { return false }
        if let keyWindow, keyWindow !== window, isDescendant(keyWindow, of: window) { return true }
        guard !modifiers.contains(.command), mainWindow == nil || mainWindow === window else { return false }
        guard let keyWindow, keyWindow !== window else { return true }
        // A panel of the app (the palette, the quick composer, the Chief pet) that belongs to no other window.
        return keyWindow is NSPanel && topParent(of: keyWindow) === keyWindow
    }
}

@MainActor private func isDescendant(_ child: NSWindow, of ancestor: NSWindow) -> Bool {
    var parent = child.parent
    while let current = parent {
        if current === ancestor { return true }
        parent = current.parent
    }
    return false
}

@MainActor private func topParent(of window: NSWindow) -> NSWindow {
    var top = window
    while let parent = top.parent { top = parent }
    return top
}
