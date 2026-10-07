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

/// The one owner of "this mouse-down moves the window".
///
/// A full-size-content window can be moved three ways: the window server's
/// titlebar drag region (the band minus the views AppKit counts as
/// claiming the mouse, precomputed from view geometry and refreshed
/// lazily), `isMovableByWindowBackground` with `mouseDownCanMoveWindow`,
/// and `performDrag(with:)`. cmux windows use only the last one, from here:
/// - The band's drag region is empty: the window's root places one
///   band-wide `TitlebarDragBlocker` (`layoutBandBlocker`), whose geometry
///   depends only on the window's size, so it is never stale.
/// - `isMovableByWindowBackground` stays false.
/// - The window's `sendEvent` asks `decide` for every left mouse-down in
///   the band and runs `WindowTitlebar.handleMouseDown` (drag or the
///   double-click action) only for `.movesWindow`.
///
/// `decide` asks the first `TitlebarPressDeciding` view from the hit view
/// up (a top-row strip answers for its full height). With none, inside the band, AppKit's background rule applies: the window moves only
/// when no view on the way is a control and every one has
/// `mouseDownCanMoveWindow` true (plain backgrounds, gaps between panes).
@MainActor
public struct TitlebarDragPolicy {
    public init() {}
    /// The titlebar band in window coordinates: the content view's area
    /// above `contentLayoutRect` (empty in fullscreen or without a titlebar).
    public static func bandRect(in window: NSWindow) -> CGRect {
        guard let content = window.contentView else { return .zero }
        let bounds = content.convert(content.bounds, to: nil)
        let top = window.contentLayoutRect.maxY
        guard bounds.maxY > top else { return .zero }
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
    }

    /// What a left mouse-down at `windowPoint` does to `window`.
    public static func decide(at windowPoint: CGPoint, in window: NSWindow) -> TitlebarPress {
        let band = bandRect(in: window)
        // Only the band and the top row's strips (a strip can be taller than the band) can move the window.
        guard band.height > 0, windowPoint.y >= min(band.minY, band.maxY - Metrics.tabStripHeight), let frameView = window.contentView?.superview,
              let hit = frameView.hitTest(frameView.convert(windowPoint, from: nil)) else { return .staysPut }
        var view: NSView? = hit
        var background = true
        while let current = view {
            if let decider = current as? TitlebarPressDeciding { return decider.titlebarPress(atWindowPoint: windowPoint) }
            if current is NSControl || !current.mouseDownCanMoveWindow { background = false }
            if current === window.contentView { break }
            view = current.superview
        }
        // Outside the content view (traffic lights, the titlebar container)
        // AppKit handles the press itself.
        guard view === window.contentView, band.contains(windowPoint) else { return .staysPut }
        return background ? .movesWindow : .staysPut
    }

    /// Sizes `blocker` (a subview of `root`, the window's content view) to
    /// the titlebar band. Call from `root`'s `layout()`.
    public static func layoutBandBlocker(_ blocker: TitlebarDragBlocker, in root: NSView) {
        guard let window = root.window else { return }
        let frame = root.convert(bandRect(in: window), from: nil)
        if blocker.frame != frame { blocker.frame = frame }
    }
}
