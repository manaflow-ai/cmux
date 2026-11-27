public import AppKit
import CoreGraphics

/// The outside facts a focus-follows-mouse decision reads (`layout.focusFollowsMouse`):
/// how long ago a key was typed, whether the window is the key window, and whether
/// a mouse button is held.
///
/// The defaults read the system. Tests inject fixed values, so a test needs
/// no key window and no real keyboard.
///
/// ```swift
/// let root = LayoutRootView(model: model, contentProvider: panes,
///                           scrollFocusSignals: ScrollFocusSignals(secondsSinceKeyDown: { 30 }, windowIsKey: { _ in true }))
/// ```
public struct ScrollFocusSignals {
    /// Seconds since the last key-down event.
    public var secondsSinceKeyDown: @MainActor () -> TimeInterval
    /// Whether `window` is the key window (a scroll over a background window never moves focus).
    public var windowIsKey: @MainActor (NSWindow) -> Bool
    /// Whether a mouse button is held (a drag or selection never moves focus on hover).
    public var mouseButtonsDown: @MainActor () -> Bool

    /// Makes the signals.
    /// - Parameter secondsSinceKeyDown: seconds since the last key-down; the
    ///   default asks the window server (`CGEventSource`), which needs no event monitor on the typing path.
    /// - Parameter windowIsKey: the key-window check; the default is `NSWindow.isKeyWindow`.
    /// - Parameter mouseButtonsDown: the held-button check; the default is `NSEvent.pressedMouseButtons`.
    public init(secondsSinceKeyDown: @escaping @MainActor () -> TimeInterval = {
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                },
                windowIsKey: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow },
                mouseButtonsDown: @escaping @MainActor () -> Bool = { NSEvent.pressedMouseButtons != 0 }) {
        self.secondsSinceKeyDown = secondsSinceKeyDown
        self.windowIsKey = windowIsKey
        self.mouseButtonsDown = mouseButtonsDown
    }
}
