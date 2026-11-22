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
    public mutating func viewSized(_ grid: TerminalGridSize, force: Bool = false) -> TerminalGridSize? {
        desired = grid
        guard ownsGeometry, force || grid != reported else { return nil }
        reported = grid
        return grid
    }

    /// The PTY owner announced `grid` at this point in the stream.
    public mutating func announce(_ grid: TerminalGridSize) {
        announced = grid
    }
}
