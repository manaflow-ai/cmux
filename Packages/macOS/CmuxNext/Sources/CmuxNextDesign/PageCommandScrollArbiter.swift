public import AppKit

/// Answers whether a web page uses Command + scroll itself, so the layout can let it keep one.
///
/// Command + scroll moves the layout's columns and rows (`layout.scrollModifier`). Some web apps
/// use the same input: Figma and Excalidraw zoom their canvas with it. With
/// `layout.pagesHandleCommandScroll` on, the layout holds a Command scroll that starts over a
/// page's own window and asks this arbiter first. When the page cancels the wheel event
/// (`preventDefault`), the held events go to the page and it keeps the gesture; otherwise the
/// layout moves the columns with them.
///
/// The browser engine conforms (`CEFEngine`); the app passes it to the layout at its
/// composition root. Tests pass a fake that answers at once.
///
/// ```swift
/// let layout = LayoutRootView(model: model, contentProvider: panes, pageCommandScroll: cefEngine)
/// ```
@MainActor
public protocol PageCommandScrollArbiter: AnyObject {
    /// Whether the page under `locationInWindow` in `window` cancels a Command + wheel event there.
    ///
    /// Called once per Command gesture or wheel burst that starts in a page window. Answer from the
    /// page itself; the layout gives up waiting after a short deadline and moves the columns.
    /// - Parameters:
    ///   - window: The page's own child window the event came from.
    ///   - locationInWindow: The pointer, in `window`'s coordinates.
    /// - Returns: True when the page handles Command + scroll there; false when it does not, or
    ///   when no page is there.
    func pageHandlesCommandScroll(in window: NSWindow, at locationInWindow: NSPoint) async -> Bool
}
