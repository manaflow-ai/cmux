public import AppKit

/// The app's key state a press reads: `NSApp`'s, or a test's (test windows are never key).
public struct AppKeyState {
    /// The app's key window.
    public var keyWindow: NSWindow?
    /// The app's main window.
    public var mainWindow: NSWindow?
    /// Whether the app is the active app.
    public var isActive: Bool
    /// Whether a modal session runs.
    public var isModal: Bool

    /// A key state with these values.
    public init(keyWindow: NSWindow?, mainWindow: NSWindow?, isActive: Bool, isModal: Bool) {
        self.keyWindow = keyWindow
        self.mainWindow = mainWindow
        self.isActive = isActive
        self.isModal = isModal
    }
}

/// What a window does with a press before AppKit gets it, for a window's `sendEvent(_:)`.
///
/// A press while this window's Chromium page, a panel or no window holds the key acts at once (``FirstClickPolicy``):
/// made key first, AppKit gives the press to the view under it instead of spending it on making the window key.
///
/// ```swift
/// override func sendEvent(_ event: NSEvent) {
///     if presses.willSend(event, in: self) { return }
///     super.sendEvent(event)
/// }
/// ```
@MainActor
public final class WindowPressRouter {
    /// The app's key state (`NSApp`); a seam for tests.
    public var appKeyState: () -> AppKeyState = {
        AppKeyState(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow, isActive: NSApp.isActive, isModal: NSApp.modalWindow != nil)
    }
    /// Makes the window key before a press that acts at once; a seam for tests.
    public var makeKey: (NSWindow) -> Void = { $0.makeKey() }

    /// Makes the router.
    public init() {}

    /// Runs before `window` sends `event` on.
    ///
    /// - Parameter event: The event `window.sendEvent(_:)` got.
    /// - Parameter window: The window the event is for.
    /// - Returns: Whether the event was delivered here; the window then does not send it on.
    public func willSend(_ event: NSEvent, in window: NSWindow) -> Bool {
        let app = appKeyState()
        if FirstClickPolicy().takesFirstClick(event, in: window, keyWindow: app.keyWindow, mainWindow: app.mainWindow,
                                              appIsActive: app.isActive, appIsModal: app.isModal) { makeKey(window) }
        return false
    }
}
