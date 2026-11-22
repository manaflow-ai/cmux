public import AppKit

/// Keeps an embedded Chromium page window out of Mission Control
/// (https://github.com/manaflow-ai/cmux/issues/48535).
///
/// A hosted page (``CEFLayerHosting``) draws in the cmux window's own layers;
/// its `CefNSWindow` is only the page's input window, a child of the cmux
/// window that draws nothing. Mission Control still laid that window out as a
/// window of its own. A page that waits off screen (the New Tab spare in
/// `PageOffscreenParking`, a page painting before its pane takes it, a hidden
/// agent page in its render window) keeps its input window there, 100 000
/// points outside the cmux window, so Mission Control fit a layout about
/// 100 000 points wide on the screen and every window, the other apps' too,
/// shrank to nothing. Hiding cmux (Cmd-H) hid those windows and the others
/// came back.
///
/// An embedded page window is `.transient` ("hidden by Exposé"), as the cmux
/// window's other child panels are (divider catchers, the overlay host): the
/// cmux window's thumbnail still shows the page, which it draws. A page window
/// that is not embedded (a page in a window of its own, undocked DevTools)
/// keeps its own behavior.
public struct ChromiumPageWindowMissionControl {
    public init() {}
    /// The Exposé behaviors AppKit allows one of at a time (setting two raises).
    private static let exposeGroup: NSWindow.CollectionBehavior = [.managed, .transient, .stationary]

    /// Marks `child`, a window being added as a child of a cmux window, `.transient` when it is an
    /// embedded Chromium page window (its class answers the fork's
    /// `isEmbeddedInParentView`, and says yes). Call it from the parent's `addChildWindow(_:ordered:)` override.
    /// - Returns: Whether `child` is an embedded page window (it is transient after the call).
    @MainActor @discardableResult
    public static func keepOut(_ child: NSWindow) -> Bool {
        guard ChromiumPageWindowVisibility.isEmbeddedPage(child) else { return false }
        let behavior = child.collectionBehavior
        guard !behavior.contains(.transient) || !behavior.isDisjoint(with: [.managed, .stationary]) else { return true }
        child.collectionBehavior = behavior.subtracting(exposeGroup).union(.transient)
        return true
    }
}
