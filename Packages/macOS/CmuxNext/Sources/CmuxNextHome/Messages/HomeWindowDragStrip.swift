public import AppKit
public import CmuxNextDesign

/// A thin strip over the Messages page's top edge that moves the window, as the native list's
/// header did (a web view never moves its window). It takes the app's one titlebar path
/// (``TitlebarDragPolicy``): it answers `.movesWindow` for its points, and the window's
/// `sendEvent` runs the drag or the double-click action (`WindowTitlebar.handleMouseDown`) once.
/// Its own mouse-down does nothing, so one press never moves the window twice.
public final class HomeWindowDragStrip: NSView, TitlebarPressDeciding {
    public static let height: CGFloat = 8

    override public var mouseDownCanMoveWindow: Bool { true }

    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .movesWindow }

    /// The window's `sendEvent` handles the press (``TitlebarDragPolicy``); the page under the strip gets none.
    override public func mouseDown(with event: NSEvent) {}
}
