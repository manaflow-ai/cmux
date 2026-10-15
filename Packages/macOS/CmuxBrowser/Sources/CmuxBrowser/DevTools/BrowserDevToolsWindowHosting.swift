public import AppKit

/// The window that holds a page's DevTools view while it is not docked.
///
/// ``BrowserDevToolsWindow`` is the AppKit implementation; tests pass a fake through
/// ``BrowserDevToolsPaneController``'s window factory.
@MainActor
public protocol BrowserDevToolsWindowHosting: AnyObject {
    /// Called when the user closes the window; the controller closes DevTools.
    var onClose: (() -> Void)? { get set }
    /// The window title.
    var title: String { get set }
    /// Moves `view` into the window, filling it.
    /// - Parameter view: The DevTools host view.
    func adopt(_ view: NSView)
    /// Shows the window.
    func show()
    /// Hides and releases the window.
    func dismiss()
    /// Whether `window` is this DevTools window or a child of it (the engine's DevTools surface).
    /// - Parameter window: A window that became key.
    /// - Returns: `true` when key focus is on these DevTools.
    func contains(_ window: NSWindow) -> Bool
}
