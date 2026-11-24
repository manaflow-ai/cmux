import AppKit

/// Lockstep resize (Leo, 2026-11-24): in a person's resize gesture a terminal's bounds follow its pane in the divider's
/// commit, ahead of a frame Ghostty has not drawn yet (``TerminalFramePresenter``, "Lockstep").
extension TerminalSurfaceView {
    /// Lockstep (Leo, 2026-11-24: "it lags, it doesn't follow in lockstep. i want all our resizing at any cpu to be able
    /// to happen in lockstep"): while a person drags a divider, a window edge or the sidebar, the view's bounds follow its
    /// pane in the layout pass that moves the divider, whether or not Ghostty drew the new size yet. A frame that is not
    /// drawn by that commit shows from the top-left of the new bounds (Ghostty's `contentsGravity`), clipped by them or
    /// beside the host's terminal background, as Chromium shows a page's old surface in a resized view; the frame of the
    /// newest size replaces it when the presenter's pass finds it drawn. One size is asked of Ghostty at a time, as outside
    /// lockstep: a new size per refresh would drop each frame Ghostty is still drawing, and under load none would show.
    /// It stays on until a frame of the bounds' size shows (``TerminalFrameOwnership/boundsAhead``), so a gesture's end never
    /// puts the bounds back behind the pane.
    var locksBoundsToPane: Bool { isFollowingResizeGesture || frameOwnership.boundsAhead != nil }

    /// The size of the frame Ghostty shows now, as far as the view's geometry knows: its bounds', unless they went ahead.
    var shownSize: CGSize { frameOwnership.boundsAhead ?? bounds.size }

    /// The bounds take `wanted` without a new size for Ghostty (the size in flight stays the one drawn), and the frame
    /// shown now stays as it is: outside the Core Animation lock, as a bounds change with no present (the lock pairs a
    /// present with its bounds; an early commit of these bounds shows the same frame from the same corner).
    func takeBoundsAhead(_ wanted: CGRect) { // perf-hot: 1ms motion-frame (each frame of a resize gesture)
        guard frame != wanted else { return }
        if frameOwnership.boundsAhead == nil { frameOwnership.boundsAhead = bounds.size }
        frameOwnership.landing = true
        frame = wanted
        frameOwnership.landing = false
        layer?.frame = wanted
        if frameOwnership.boundsAhead == wanted.size { frameOwnership.boundsAhead = nil }
    }

    /// The gesture ended with the bounds ahead of the shown frame and no size in flight: the frame of the bounds' size is
    /// asked now (the bounds stay; the presenter lands it as any request).
    func settleBoundsAhead() {
        guard frameOwnership.boundsAhead != nil, frameOwnership.inFlight == nil else { return }
        requestWantedFrame()
    }
}
