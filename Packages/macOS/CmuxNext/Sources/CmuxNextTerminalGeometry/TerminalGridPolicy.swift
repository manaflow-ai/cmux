/// Which grid one terminal surface renders and which grid it reports.
///
/// Two grids meet here: the grid the view's pixel size fits (`desired`) and
/// the grid the PTY owner announced (`announced`, a `.resize` event in
/// stream order). A mirror must render the PTY's grid at every point in the
/// byte stream, or output lands in the wrong cells, and a shell that pads
/// to `$COLUMNS` (zsh's PROMPT_SP `%` mark after Ctrl-C) wraps visibly.
///
/// One owner decides PTY geometry: whoever announces grids (the cmux-tui
/// daemon). Once a grid was announced the surface renders only announced
/// grids. The view's own grid is a request: an owner reports it once per
/// change, and the surface resizes when the announcement that applies it
/// arrives. A request the daemon does not apply (another client holds
/// geometry, a report coalesced away, a release) therefore never shows as a
/// grid the PTY does not have. A terminal whose IO never announces (a bare
/// local PTY, resized synchronously by the report) renders the view grid.
public nonisolated struct TerminalGridPolicy: Sendable {
    /// Whether this view's size is reported to the PTY owner.
    public var ownsGeometry: Bool
    /// Latest grid the PTY owner announced.
    public private(set) var announced: TerminalGridSize?
    /// Latest grid the view's pixel size fits.
    public private(set) var desired: TerminalGridSize?
    /// Last grid reported to the PTY owner.
    public private(set) var reported: TerminalGridSize?

    public init(ownsGeometry: Bool) {
        self.ownsGeometry = ownsGeometry
    }

    /// The grid the surface renders: the announced grid once there is one,
    /// the view's fit before that.
    public var rendered: TerminalGridSize? { announced ?? desired }

    /// The grid to impose on the surface, or nil to size it to the view
    /// (nothing announced yet).
    public var gridToRender: TerminalGridSize? { announced }

    /// The view now fits `grid`. Returns the grid to report, if any: each
    /// distinct grid once, or again when `force` is set (a new owner).
    ///
    /// `holding`: the view is on a layout spring (a Cmd-Shift-Enter zoom, a split, a close), so
    /// its size changes on every display frame. The grid is not reported then: each report is a
    /// PTY resize, a shell redraw and a reflow at the owner, and announcements arriving frames
    /// behind the view made the zoom stutter and its text jump. ``releaseHeld()`` reports the
    /// last held grid once, when the spring lands.
    public mutating func viewSized(_ grid: TerminalGridSize, force: Bool = false, holding: Bool = false) -> TerminalGridSize? {
        desired = grid
        guard ownsGeometry, force || heldForce || grid != reported else {
            held = false
            return nil
        }
        guard !holding else {
            held = true
            heldForce = heldForce || force
            return nil
        }
        (held, heldForce) = (false, false)
        reported = grid
        return grid
    }

    /// Whether a grid waits for ``releaseHeld()``.
    public private(set) var held = false
    private var heldForce = false

    /// The grid the view's layout spring will land at, reported at its start (``finalSized(_:)``);
    /// nil at rest.
    public private(set) var final: TerminalGridSize?

    /// The view's layout spring (a split, a close) will land at a size that fits `grid`. Returns the
    /// grid to report now, at the start (nil when the owner already has it): the program in the
    /// terminal redraws at its final size while the pane moves (Lawrence 2026-10-23), and the
    /// landing at that grid reports nothing more (``releaseHeld()``).
    public mutating func finalSized(_ grid: TerminalGridSize) -> TerminalGridSize? {
        guard ownsGeometry else { return nil }
        final = grid
        guard heldForce || grid != reported else { return nil }
        heldForce = false
        reported = grid
        return grid
    }

    /// Whether the surface may draw its reflow preview (the view's grid, before the owner announces
    /// it): not while a final grid was reported that the view does not fit yet. The owner's grid is
    /// then the final one, drawn cropped or padded in the moving view, never reflowed back to the
    /// view's size of the frame.
    public var previewsViewGrid: Bool {
        guard let final else { return true }
        return final == desired
    }

    /// The view's layout spring landed (or stopped): its final grid no longer stands in for the view's.
    public mutating func motionLanded() {
        final = nil
    }

    /// The layout spring landed: the grid held while it moved, to report once (nil when none
    /// waits or the view is back at the reported grid, the final grid sent at the start).
    public mutating func releaseHeld() -> TerminalGridSize? {
        final = nil
        guard held, let desired else { return nil }
        return viewSized(desired)
    }

    /// The PTY owner announced `grid` at this point in the stream.
    public mutating func announce(_ grid: TerminalGridSize) {
        announced = grid
    }
}
