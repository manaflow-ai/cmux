import Foundation

/// A developer tools request from a shortcut, menu, context menu or automation.
///
/// The same commands drive both engines: the WebKit inspector and Chromium DevTools.
public enum BrowserDevToolsCommand: Hashable, Sendable {
    /// Opens the tools when closed and closes them when open (Cmd-Opt-I).
    case toggle
    /// Opens the tools, or focuses them when already open.
    case show
    /// Opens the tools on the Console panel (the Show Browser JavaScript Console shortcut).
    case console
    /// Starts picking an element in the page to inspect.
    case inspectElement
    /// Inspects the element at a point of the page, in page (view) coordinates with a top-left
    /// origin, as the page context menu's Inspect does.
    case inspect(x: Int, y: Int)
    /// Closes the tools.
    case close
    /// Moves the tools to another dock; the same tools keep their state when the engine can
    /// reparent them.
    case dock(BrowserDevToolsDock)
}
