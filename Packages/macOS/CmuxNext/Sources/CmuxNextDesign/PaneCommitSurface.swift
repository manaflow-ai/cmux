public import AppKit

/// A view in a pane whose pixels come from another thread or another process (a terminal's surface, a page), as a
/// layout commit reads it.
///
/// A layout change whose end is known when it starts (a split, a close, a zoom, an unzoom) shows in one commit: every
/// pane takes its new frame, and every pane's content its new size, in one presented frame. A view that draws in this
/// process lays out in that frame's pass and needs none of this. A producer on another thread or in another process
/// draws its new size some refreshes after it hears it, so the commit tells it the size ahead and waits for it, for a
/// bounded number of refreshes (`ScreenContentView.commitBound`). A producer that is still not ready then is late:
/// its pane shows its own ground over its content area, never the producer's old picture at the new size, until the
/// producer reports.
///
/// The pane's layout asks the pane's content for its surfaces in the change's own turn
/// (`NSView.paneCommitSurfaces()`): the content's root view when it is one, else the surfaces the root names
/// (``PaneCommitSurfaceHosting``). It walks no view tree, so a view the root does not name takes no part.
///
/// A surface that hides or leaves its pane while it still owes a report calls `ready` then: it will not draw, and its
/// pane shows its ground until every report it is owed came, or until its next commit finds the surface gone.
@MainActor
public protocol PaneCommitSurface: NSView {
    /// The next commit of this view's pane changes this view's size by `change` (points; negative: smaller). The pane
    /// chrome around the view keeps its size, so the view's size in that commit is its `bounds.size` plus `change`.
    /// The view draws for that size now and keeps showing what it shows.
    ///
    /// Called once per layout change, in the change's turn, on the main actor. A later call replaces an earlier one,
    /// and the earlier `ready` need not be called then.
    ///
    /// - Parameters:
    ///   - change: How much larger the view is in the commit.
    ///   - ready: Call it once, on the main actor, when a picture drawn for the new size shows in a commit made from
    ///     then on; in this call when one already does.
    func commitWillResize(by change: CGSize, ready: @escaping @MainActor () -> Void)
}

public extension NSView {
    /// The ``PaneCommitSurface``s of this view as the root of a pane's content: the view itself when it is one, else
    /// the ones it names (``PaneCommitSurfaceHosting``), and none for any other view. A hidden view has none: it draws
    /// nothing and takes its size when it shows.
    ///
    /// No walk of the subtree: a layout change asks each resized pane once, in its own turn, and a pane with no
    /// surface costs two casts there.
    ///
    /// - Returns: The surfaces that take part in the pane's next commit.
    func paneCommitSurfaces() -> [any PaneCommitSurface] {
        guard !isHidden else { return [] }
        if let surface = self as? any PaneCommitSurface { return [surface] }
        return (self as? any PaneCommitSurfaceHosting)?.commitSurfaces ?? []
    }
}
