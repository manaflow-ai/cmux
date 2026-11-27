public import AppKit

/// ``KeyWindowSwitching`` on AppKit: `NSApp.keyWindow` and `NSWindow.makeKey()`.
public final class AppKitKeyWindows: KeyWindowSwitching {
    /// A switcher of the running app's key window.
    public init() {}

    /// `NSApp.keyWindow`.
    public var keyWindow: NSWindow? { NSApp.keyWindow }

    /// `window.isKeyWindow`.
    ///
    /// - Parameter window: The window to test.
    /// - Returns: Whether AppKit reports `window` as key.
    public func isKey(_ window: NSWindow) -> Bool { window.isKeyWindow }

    /// `window.makeKey()`.
    ///
    /// - Parameter window: The window that takes the keys.
    public func makeKey(_ window: NSWindow) { window.makeKey() }
}
