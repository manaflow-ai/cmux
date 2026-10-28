public import AppKit

/// Reads and changes the app's key window.
///
/// The app uses ``AppKitKeyWindows``; a test passes a recorder that counts key-window changes
/// (each one makes AppKit walk both windows' view trees and may activate the input method).
public protocol KeyWindowSwitching: AnyObject {
    /// The app's key window, if any.
    var keyWindow: NSWindow? { get }
    /// Whether `window` is the key window.
    ///
    /// - Parameter window: The window to test.
    /// - Returns: Whether `window` has the keys now.
    func isKey(_ window: NSWindow) -> Bool
    /// Makes `window` key: one key-window change.
    ///
    /// - Parameter window: The window that takes the keys.
    func makeKey(_ window: NSWindow)
}
