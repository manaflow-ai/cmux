public import AppKit

/// What a left mouse-down in a window's titlebar band does to the window.
public enum TitlebarPress: Equatable, Sendable {
    /// The window moves with the pointer (a double-click runs the user's
    /// titlebar action instead).
    case movesWindow
    /// The view under the pointer handles the press; the window stays.
    case staysPut
}

/// A view in the titlebar band that decides, per point, whether a press on
/// it moves the window (`TitlebarDragPolicy`). The tab strip says
/// `.staysPut` for every point a tab drag can start from.
@MainActor
public protocol TitlebarPressDeciding: AnyObject {
    /// `windowPoint` is in window coordinates.
    func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress
}

/// The one owner of "this mouse-down moves the window" (stub).
@MainActor
public enum TitlebarDragPolicy {
    public static func bandRect(in window: NSWindow) -> CGRect { .zero }

    public static func decide(at windowPoint: CGPoint, in window: NSWindow) -> TitlebarPress { .staysPut }

    public static func layoutBandBlocker(_ blocker: TitlebarDragBlocker, in root: NSView) {}
}
