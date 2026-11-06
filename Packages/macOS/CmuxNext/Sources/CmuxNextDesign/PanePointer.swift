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

/// The hover targets (``PointerHover``) and themed tooltips inside a layout screen, served by the screen's one pointer
/// area as Chrome serves every view of a widget from one native area: they own no tracking area, which AppKit would
/// move with the pane in every frame of a resize and rebuild the window's drag margins and tracking areas for
/// (`PaneTrackingAreaOwnersTests`: the strip's new-tab and pane-type buttons, their tooltips and the strip scrollbar,
/// 13 areas in a 2x2 layout; 0.85 ms of each STRESS drag frame). The screen tells it each pointer move; it finds the
/// targets under the pointer by geometry and refreshes hover and tooltips when that set changes, as the targets' own
/// enter and exit did.
@MainActor
public final class PanePointerTargets {
    /// The views with a served hover target under the pointer, as of the last move.
    private var hovered: Set<ObjectIdentifier> = []
    /// The served tooltip under the pointer (the deepest), as of the last move.
    private weak var tooltip: TooltipTracker?

    public init() {}

    /// The views below `root` give up their own hover and tooltip areas: when the screen joins a window and when a
    /// motion starts (a target made since joins then), never per frame.
    public func adopt(in root: NSView) {
        var stack = [root]
        while let view = stack.popLast() {
            PointerHover.adoptServed(view)
            TooltipTracker.adoptServed(view)
            stack.append(contentsOf: view.subviews)
        }
    }

    /// The pointer is at `windowPoint` in `root`'s window, or left `root` (nil).
    public func follow(_ windowPoint: NSPoint?, in root: NSView) {
        var under: Set<ObjectIdentifier> = []
        var deepest: (tracker: TooltipTracker, depth: Int)?
        if let windowPoint, root.window != nil, !root.isHiddenOrHasHiddenAncestor {
            var stack: [(view: NSView, point: NSPoint)] = [(root, root.convert(windowPoint, from: nil))]
            while let next = stack.popLast() {
                if PointerHover.hasServedTarget(next.view) { under.insert(ObjectIdentifier(next.view)) }
                for tracker in TooltipTracker.served(of: next.view) where tracker.contains(windowPoint) {
                    let depth = tracker.depth
                    if depth > deepest?.depth ?? -1 { deepest = (tracker, depth) }
                }
                for sub in next.view.subviews where !sub.isHidden && sub.frame.contains(next.point) {
                    stack.append((sub, sub.convert(next.point, from: next.view)))
                }
            }
        }
        if under != hovered {
            hovered = under
            PointerHover.refresh(in: root.window)
        }
        // A tooltip shows only in the active app, as its own area (`.activeInActiveApp`) did.
        let tip = NSApp.isActive || WindowPlacement.noActivate ? deepest?.tracker : nil
        guard tip !== tooltip else { return }
        if let tooltip { TooltipPresenter.shared.exit(tooltip) }
        tooltip = tip
        if let tip { TooltipPresenter.shared.enter(tip) }
    }
}
