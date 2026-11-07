public import AppKit

/// A view that takes its pointer from the one pointer area of the layout screen it sits in, never from a tracking
/// area or cursor rects of its own (Chrome's model: one native tracking area per screen, which does not move with the
/// panes, hit-tests the current frames for the hover, the moves and the cursor). AppKit moves a view's own tracking
/// areas and cursor rects with its frame: each pane that moved in a frame made it invalidate cursor rects, walk the
/// window's views and rebuild the window's drag margins and tracking areas in that display cycle (RESIZE MAIN BUDGET,
/// `PaneMotionPointerAreasTests`; the divider handles do the same through `ScreenDividerPointer`). A view outside such
/// an area (``NSView/enclosingPanePointerArea`` nil) keeps its own tracking area and cursor rects.
@MainActor
public protocol PanePointerFollowing: NSView {
    /// The cursor the pointer shows at `point` (this view's coordinates); nil: the view sets none (the arrow, or what
    /// AppKit's cursor rects of the views around set).
    func panePointerCursor(at point: NSPoint) -> NSCursor?
    /// The pointer came into this view (the area's hit test finds it now), with no button down.
    func panePointerEntered(with event: NSEvent)
    /// The pointer moved inside this view, with no button down.
    func panePointerMoved(with event: NSEvent)
    /// The pointer left this view (another view or none is under it now, or it left the area).
    func panePointerExited(with event: NSEvent)
}

/// A region that hears the pointer come in and leave by geometry, not by the hit test (a probe that takes no clicks,
/// a rect that spans two views), from the area it registered with (``PanePointerArea/addPointerRegion(_:)``).
@MainActor
public protocol PanePointerRegion: AnyObject {
    /// The view the region is in, and the region in that view's coordinates; nil: no region now.
    var panePointerRegion: (view: NSView, rect: CGRect)? { get }
    /// The pointer came into the region or left it.
    func panePointerInside(_ inside: Bool)
}

/// The view whose one tracking area serves the ``PanePointerFollowing`` views and ``PanePointerRegion``s inside it (a
/// layout screen). It keeps each region weakly.
@MainActor
public protocol PanePointerArea: NSView {
    func addPointerRegion(_ region: any PanePointerRegion)
    func removePointerRegion(_ region: any PanePointerRegion)
}

extension NSView {
    /// The ``PanePointerArea`` above this view that delivers its pointer, if any: it then needs no tracking area and no
    /// cursor rects of its own.
    public var enclosingPanePointerArea: (any PanePointerArea)? {
        var view = superview
        while let current = view {
            if let area = current as? any PanePointerArea { return area }
            view = current.superview
        }
        return nil
    }

    /// Whether a ``PanePointerArea`` above this view delivers its pointer.
    public var isServedByPanePointerArea: Bool { enclosingPanePointerArea != nil }
}
