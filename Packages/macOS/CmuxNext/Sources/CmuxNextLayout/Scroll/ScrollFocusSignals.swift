public import AppKit
import CoreGraphics

/// The outside facts a scroll-to-focus decision reads (`layout.focusPaneOnScroll`):
/// how long ago a key was typed, and whether the window is the key window.
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

    /// Makes the signals.
    /// - Parameter secondsSinceKeyDown: seconds since the last key-down; the
    ///   default asks the window server (`CGEventSource`), which needs no event monitor on the typing path.
    /// - Parameter windowIsKey: the key-window check; the default is `NSWindow.isKeyWindow`.
    public init(secondsSinceKeyDown: @escaping @MainActor () -> TimeInterval = {
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                },
                windowIsKey: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow }) {
        self.secondsSinceKeyDown = secondsSinceKeyDown
        self.windowIsKey = windowIsKey
    }
}
